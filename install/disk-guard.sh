# The disk guard: the first of a host's autoinstall early-commands.
# install/render.py embeds this file in each host's user-data after two
# lines that set INSTALL_DISK_SERIAL and INSTALL_DISK_MODEL from hosts.yml.
#
# It runs in the installer, before Subiquity touches any disk, and fails
# (which stops the install) unless:
#   - the machine booted in UEFI mode, and
#   - exactly one disk carries the serial, and
#   - that disk's model is INSTALL_DISK_MODEL, when that is set.
# A disk carries the serial when lsblk's SERIAL, or the udev property
# ID_SERIAL, ID_SERIAL_SHORT or ID_SCSI_SERIAL, contains it. That is a
# superset of the disks Subiquity's `match: serial: "*<serial>*"` picks
# (it globs ID_SERIAL), so the storage match can only pick this disk.
#
# POSIX sh: Subiquity runs each early-command with `sh -c`.
set -eu
say() {
    echo "install-stick: $*" >&2
    echo "install-stick: $*" >/dev/console 2>/dev/null || true
}
serial=${INSTALL_DISK_SERIAL:?}
model=${INSTALL_DISK_MODEL:-}
# INSTALL_EFI_DIR is for scripts/test-make-install-stick only.
if [ ! -d "${INSTALL_EFI_DIR:-/sys/firmware/efi}" ]; then
    say "booted in legacy BIOS mode: boot the stick's UEFI entry; refusing to install"
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
    lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN >/dev/console 2>/dev/null || true
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
say "installing onto $dev (serial $serial)"
