#!/bin/sh
# Runs ON THE BMC (ansible.builtin.script from bootstrap.yml), only when an
# RK1's old OS could not wipe its own NVMe before the flash. Powers node
# slot N on, stops U-Boot's autoboot over the UART, zeroes the first 1 MiB
# of the NVMe (protective MBR and primary GPT), so the staging OS cannot
# mount a stale Ubuntu install by label, then resets into the staging OS.
# The backup GPT at the end of the disk is left: nothing boots from it, and
# the install in move_fs rewrites the disk.
#
# - U-Boot only sees the NVMe after `pci enum`.
# - U-Boot does not read the UART while a command runs, so send one
#   command at a time and wait; back-to-back input is dropped or merged.
# - reset, not boot, afterwards: U-Boot still holds the NVMe's old
#   partition table in memory and may have loaded EFI boot entries from it.
#
# usage: rk1_zap_nvme.sh <slot>
set -e
N=$1
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
for c in 'echo ZAPSTART' 'pci enum' 'nvme scan' 'nvme info' \
  'mw.b 0x02000000 0 0x100000' 'nvme write 0x02000000 0 0x800' \
  'mw.b 0x00c00000 0xff 0x200' 'nvme read 0x00c00000 0 1' 'md.b 0x00c001f0 0x10' 'echo ZAPDONE'; do
  tpi uart -n "$N" set -c "$c" >/dev/null
  sleep 2
done
out=$(tpi uart -n "$N" get | tr -d '\r')
echo "$out" | sed -n '/ZAPSTART/,$p' | awk '!seen[$0]++'
echo "$out" | grep -q '2048 blocks written: OK' || {
  echo "NVMe zap FAILED: the node is left at the U-Boot prompt" >&2
  exit 1
}
tpi uart -n "$N" set -c 'reset' >/dev/null
