#!/bin/sh
# Runs ON THE BMC (ansible.builtin.script from bootstrap.yml), after the
# eMMC flash of an RK1 with root_dev. Powers node slot N on, stops U-Boot's
# autoboot over the UART and reads the NVMe's first two sectors. Then:
#
# - force: zeroes the first 1 MiB of the NVMe (protective MBR and primary
#   GPT), so the staging OS cannot mount a stale Ubuntu install by label;
# - check: if the NVMe has a partition table (an MBR signature in LBA 0 or
#   a GPT header in LBA 1), writes nothing, powers the node off and exits 3;
#   a blank NVMe has nothing to clear and is left as it is.
#
# Either way it then resets into the staging OS. The backup GPT at the end
# of the disk is left: without the protective MBR neither Linux nor U-Boot
# uses it, and the install in move_fs rewrites the disk.
#
# - U-Boot only sees the NVMe after `pci enum`.
# - U-Boot does not read the UART while a command runs, so send one
#   command at a time and wait; back-to-back input is dropped or merged.
# - reset, not boot, afterwards: U-Boot still holds the NVMe's old
#   partition table in memory and may have loaded EFI boot entries from it.
# - On any failure the node is powered off, not left at the U-Boot prompt.
# - nvme read/write count logical blocks, not bytes. The offsets and counts
#   here (LBA 1 at +0x200, 0x800 blocks = the 1 MiB zero buffer) assume
#   512-byte LBAs; on a 4Kn NVMe 0x800 blocks would be 8 MiB, past the end
#   of the buffer. The script stops unless `nvme info` reports 512-byte
#   blocks.
#
# usage: rk1_zap_nvme.sh <slot> check|force
set -e
N=$1
MODE=$2
case "$MODE" in
  check | force) ;;
  *)
    echo "usage: $0 <slot> check|force" >&2
    exit 2
    ;;
esac

trap 'tpi power off -n "$N" >/dev/null 2>&1 || true' EXIT

send() {
  for c in "$@"; do
    tpi uart -n "$N" set -c "$c" >/dev/null
    sleep 2
  done
}

# Print the console output since the last read, from line $1 on.
collect() {
  tpi uart -n "$N" get | tr -d '\r' | sed -n "/$1/,\$p" | awk '!seen[$0]++'
}

tpi power off -n "$N"
sleep 3
tpi uart -n "$N" get >/dev/null
tpi power on -n "$N"
# BOOTDELAY is 1 s: keep sending keystrokes for about 10 s
i=0
while [ $i -lt 60 ]; do
  tpi uart -n "$N" set -c ' ' >/dev/null 2>&1
  i=$((i + 1))
done
sleep 1
tpi uart -n "$N" get >/dev/null

# Fill the buffer with 0xff first, so a failed read cannot look blank.
send 'echo ZAPSTART' 'pci enum' 'nvme scan' 'nvme info' \
  'mw.b 0x00c00000 0xff 0x400' 'nvme read 0x00c00000 0 2' \
  'md.b 0x00c001f0 0x10' 'md.b 0x00c00200 0x10' 'echo ZAPPROBED'
probe=$(collect ZAPSTART)
echo "$probe"
# Fail closed: both md.b lines must be there, or an empty capture would
# look like a blank NVMe.
echo "$probe" | grep -q 'ZAPPROBED' &&
  echo "$probe" | grep -q '2 blocks read: OK' &&
  echo "$probe" | grep -q '^00c001f0:' &&
  echo "$probe" | grep -q '^00c00200:' || {
  echo "NVMe zap FAILED: could not read the NVMe from the U-Boot prompt" >&2
  exit 1
}
echo "$probe" | grep -q ' x 512)' || {
  echo "NVMe zap FAILED: nvme info does not report 512-byte blocks" >&2
  exit 1
}
# md.b prints 16 bytes then two spaces, so ' 55 aa  ' is bytes 510-511.
if echo "$probe" | grep '^00c001f0:' | grep -q ' 55 aa  ' ||
  echo "$probe" | grep '^00c00200:' | grep -q 'EFI PART'; then
  table=yes
else
  table=no
fi
echo "NVMe partition table: $table"

if [ "$MODE" = check ] && [ "$table" = yes ]; then
  echo "NVMe has a partition table and flash_force is not set: not wiped" >&2
  exit 3
fi

if [ "$MODE" = force ]; then
  # 0x800 blocks of 512 bytes: the 1 MiB zeroed at 0x02000000.
  send 'echo ZAPWRITE' 'mw.b 0x02000000 0 0x100000' 'nvme write 0x02000000 0 0x800' \
    'mw.b 0x00c00000 0xff 0x200' 'nvme read 0x00c00000 0 1' 'md.b 0x00c001f0 0x10' 'echo ZAPDONE'
  out=$(collect ZAPWRITE)
  echo "$out"
  echo "$out" | grep -q '2048 blocks written: OK' &&
    echo "$out" | grep -q '^00c001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ' || {
    echo "NVMe zap FAILED: the NVMe's first 1 MiB was not zeroed" >&2
    exit 1
  }
fi

trap - EXIT
tpi uart -n "$N" set -c 'reset' >/dev/null
