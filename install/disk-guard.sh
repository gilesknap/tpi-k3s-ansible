# The disk guard: the first of a host's autoinstall early-commands.
# install/render.py embeds this file in each host's user-data after lines
# that set INSTALL_DISK_SERIAL, INSTALL_DISK_MODEL and INSTALL_MACHINE_MACS
# from hosts.yml.
#
# It runs in the installer, before Subiquity touches any disk, and fails
# (which stops the install) unless:
#   - the machine booted in UEFI mode, and
#   - one of its network ports has a MAC in INSTALL_MACHINE_MACS (this is
#     the machine: a disk serial alone is not enough, since a USB
#     enclosure reports its own serial, whatever drive is in it), and
#   - exactly one disk carries the serial, and
#   - that disk's model is INSTALL_DISK_MODEL, when that is set.
# A disk carries the serial when lsblk's SERIAL, or the udev property
# ID_SERIAL, ID_SERIAL_SHORT or ID_SCSI_SERIAL, contains it. That is a
# superset of the disks Subiquity's `match: serial: "*<serial>*"` picks
# (it globs ID_SERIAL), so the storage match can only pick this disk.
#
# POSIX sh: Subiquity runs each early-command with `sh -c`.
set -eu
# INSTALL_CONSOLE, INSTALL_EFI_DIR and INSTALL_NET_DIR are for
# scripts/test-make-install-stick only: the test points INSTALL_CONSOLE at
# /dev/null, so the guard's messages for the operator don't reach the
# terminal of whoever runs the test.
console=${INSTALL_CONSOLE:-/dev/console}
say() {
    echo "install-stick: $*" >&2
    echo "install-stick: $*" >"$console" 2>/dev/null || true
}
serial=${INSTALL_DISK_SERIAL:?}
model=${INSTALL_DISK_MODEL:-}
macs=${INSTALL_MACHINE_MACS:?}
if [ ! -d "${INSTALL_EFI_DIR:-/sys/firmware/efi}" ]; then
    say "booted in legacy BIOS mode: boot the stick's UEFI entry; refusing to install"
    exit 1
fi
# Let udev finish naming the disks and ports before they are read.
udevadm settle -t 30 || true
here=$(cat "${INSTALL_NET_DIR:-/sys/class/net}"/*/address 2>/dev/null | tr 'A-F' 'a-f' | tr '\n' ' ')
mine=""
for mac in $macs; do
    case " $here " in
    *" $mac "*) mine=$mac ;;
    esac
done
if [ -z "$mine" ]; then
    say "none of this machine's MACs ($here) is in hosts.yml ($macs): wrong machine or wrong entry; refusing to install"
    exit 1
fi
found=""
n=0
for dev in $(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}'); do
    ids="$(lsblk -dno SERIAL "$dev" 2>/dev/null || true)"
    ids="$ids $(udevadm info --query=property --name="$dev" 2>/dev/null |
        sed -n 's/^ID_SERIAL=//p; s/^ID_SERIAL_SHORT=//p; s/^ID_SCSI_SERIAL=//p' |
        tr '\n' ' ')"
    case "$ids" in
    *"$serial"*) ;;
    *) continue ;;
    esac
    n=$((n + 1))
    found="$found $dev"
done
if [ "$n" -ne 1 ]; then
    say "expected exactly one disk with serial $serial, found $n:$found; refusing to install"
    lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN >&2 || true
    lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN >"$console" 2>/dev/null || true
    exit 1
fi
dev=${found# }
if [ -n "$model" ]; then
    have=$(lsblk -dno MODEL "$dev" | sed 's/[[:space:]]*$//')
    if [ "$have" != "$model" ]; then
        say "$dev has serial $serial but model '$have', not '$model'; refusing to install"
        exit 1
    fi
fi
say "installing onto $dev (serial $serial) on the machine with MAC $mine"
