# Install Ubuntu from the install stick

One USB stick installs Ubuntu 26.04 on each x86 host: `gknas`, `nuc1` and
`nuc2`. Its GRUB menu has an entry per host and a "new hardware" entry.
A host's entry runs unattended once you pick it, and erases only that
host's OS disk. The RK1s are installed by the `flash` role instead
({doc}`/how-to/reflash-rebuild`), and `ws03` is reinstalled by hand.

## What an install does

Each host's entry is data in `hosts.yml`, as host vars:

| Variable | Meaning |
|----------|---------|
| `install_profile` | `server`, or `desktop`: Ubuntu Server plus `ubuntu-desktop-minimal`, with NetworkManager |
| `install_disk_serial` | The OS disk's serial, as `lsblk -o NAME,SERIAL` shows it. The install erases this whole disk. |
| `install_disk_model` | Optional. The OS disk's model, as `lsblk -o NAME,MODEL` shows it, checked as well. |
| `install_machine_macs` | The host's network ports' MAC addresses, in lower case (`cat /sys/class/net/*/address`). The install runs only on a machine that has one of them. |
| `install_ansible_uid` | Optional. The `ansible` account's uid, when its home is on a disk the install keeps. |

Never list a USB network dongle's MAC in `install_machine_macs`: a dongle
moves between machines, so it does not identify one. A host needs
`install_profile`, `install_disk_serial` and `install_machine_macs` to get
an entry. Without the serial or the MACs, the
build warns and leaves the host out.

| Host | Profile | OS disk | Other disks, never touched |
|------|---------|---------|-----------------------------|
| `gknas` | server | Fanxiang S500Pro 256GB NVMe in the PCIe slot, serial `26100800643000458` | The DOM (QTS), the data SSDs, the LaCie |
| `nuc1` | desktop | Samsung SSD 860 EVO M.2 250GB, serial `S5GFNG0N302036V` | None |
| `nuc2` | server | Samsung SSD 980 PRO 1TB, serial `S5GXNF0RA03936L` | The 870 QVO (`/home`), the Crucial X6 |

`gknas`'s NVMe used to sit in a JMicron USB enclosure, which reported its
own serial (`DD564198838AA`) and model (`Tech`) in place of the NVMe's.
Put back in that enclosure, the NVMe would not match `gknas`'s entry: the
install would refuse, and the entry would need the enclosure's serial and
model again.

Every install:

- refuses to start, before it touches any disk, unless:
  - the machine booted in UEFI mode;
  - one of its network ports has a MAC in `install_machine_macs`;
  - exactly one disk has the serial, and the model too when it is set;
- uses the whole OS disk: a 1 GB EFI system partition and an ext4 root,
  with a swap file, `/swap.img`, on the root;
- creates the `ansible` account with passwordless sudo, a locked password,
  and the keys in `pub_keys/ansible_rsa.pub` plus the Claude sandbox's key;
- installs `openssh-server` with password logins off;
- sets the hostname from `hosts.yml`, the locale `en_GB.UTF-8`, a UK keyboard
  and the time zone Europe/London;
- takes DHCP on every Ethernet port (the router reserves each host's
  address);
- powers off when it is done.

The menu has no default and no timeout. An install starts only when someone
picks its entry at the console, so a stick left in never starts one by
itself. Every install is attended anyway: you need the console to pick the
stick in the firmware's boot menu.

The stick holds public keys only: no passwords and no secrets.

### nuc1, the desktop

`nuc1`'s disk also holds an old Windows data partition; its install erases
it.

The desktop profile adds GNOME and hands the network to NetworkManager. It
turns `systemd-networkd` and its wait-online service off, so boot does not
wait for them. The `ansible` account has no password, so GNOME has no
account to log in with. Create your own over SSH:

```bash
ssh ansible@nuc1.lan
sudo adduser giles
sudo usermod -aG sudo giles
```

### nuc2's other disks

`nuc2`'s `/home` is the 870 QVO, which holds `/home/k8s-data`. The install
leaves that disk alone and does not mount it. The playbook mounts it again.
The `extra_mounts` host var lists `/home` and `/mnt/backup` (the Crucial
X6). The `servers` tag restores both, before it creates the data
directories.

Once `/home` is mounted, sshd reads `ansible`'s keys from
`/home/ansible/.ssh/authorized_keys` on the 870 QVO, not from the new
install. That file belongs to uid 1001, so `nuc2`'s install gives the
`ansible` account that uid (`install_ansible_uid`). It already holds both
keys. If `pub_keys/ansible_rsa.pub` has changed since, run
`pb_add_nodes.yml` for `nuc2` (as in [](node-operations.md#add-a-node),
step 3). `--tags claude_key` (step 5) re-adds the Claude key. The owner's
own login on `nuc2` is not recreated: add it as for `nuc1`.

## Build the stick

Run it on `ws03`, in the repo, not in the devcontainer: it needs the
internet, `sudo` and the stick. It needs `xorriso`, `curl` and
`python3-yaml`.

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN   # find the stick, e.g. /dev/sdb
scripts/make-install-stick --write /dev/sdb
```

The script downloads the newest Ubuntu 26.04 live-server ISO into
`build/install-stick/` and checks its SHA256. It adds the entries and
writes the stick. Before writing, it shows the device and asks you to type
the device name again and then the stick's serial (or its model, if it has
no serial). It refuses any device that is not a USB disk under 512 GB.
Without `--write` it only builds `build/install-stick/install-stick.iso`.

## Check a new stick in a VM

Before you rely on a rebuilt stick, boot its ISO once in QEMU on `ws03`.
This confirms that the menu, the seed and the guard work. The VM gets a
disk with `gknas`'s serial and model (a SATA disk: QEMU cannot set an
NVMe's model), a decoy disk, and a network port with `gknas`'s MAC (it
needs `qemu-system-x86` and `ovmf`):

```bash
cd build/install-stick
truncate -s 20G os.img decoy.img
cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd
qemu-system-x86_64 -enable-kvm -machine q35 -m 4096 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -cdrom install-stick.iso \
  -device virtio-scsi-pci \
  -drive if=none,id=os,file=os.img,format=raw \
  -device 'ide-hd,drive=os,bus=ide.0,serial=26100800643000458,model=Fanxiang S500Pro 256GB' \
  -drive if=none,id=decoy,file=decoy.img,format=raw \
  -device scsi-hd,drive=decoy,serial=DECOY0000001,product=Decoy \
  -nic user,model=virtio-net-pci,mac=24:5e:be:47:a3:05
```

Pick `Install gknas`. The install should run and power the VM off.
Afterwards, `os.img` has partitions and `decoy.img` is still all zeros:

```bash
fdisk -l os.img
cmp decoy.img /dev/zero      # "EOF on decoy.img" means it is untouched
```

Then run it again with another MAC, e.g. `mac=02:00:00:00:00:01`. The
install must stop with the guard's "refusing to install" message. Delete
the images afterwards (`rm os.img decoy.img vars.fd`).

## Install a host

1. Boot the host from the stick in UEFI mode (its `UEFI:` boot entry).
   Booted the legacy way, the menu shows no host entries.
2. Pick `Install <host>`. The install runs on its own and powers off.
3. Remove the stick and power on.
4. From the devcontainer, replace the old host key:
   `ssh-keygen -R <host>.lan`, then run the host's playbook:
   - `gknas`: {doc}`/how-to/nas-ubuntu-zfs`, from step 2;
   - `nuc1`, `nuc2`: steps 2 and 4 of
     [](node-operations.md#add-a-node). The `ansible` account and keys
     are already there, so skip steps 3 and 5.

If the install stops with an error, read the message: the guard names the
MACs and disks it saw. Nothing was written to any disk.

## New hardware

The `New hardware` entry is an ordinary interactive install. It has no
`autoinstall` on its kernel line, and its network and storage screens wait
for you, so it can never erase a disk unattended. You pick the disk
yourself. It still creates the `ansible` account with the keys, and names
the host `new-host`.

Use it to bring up a machine that is not in `hosts.yml` yet. Then either
rename it (`sudo hostnamectl set-hostname <name>`), or add it as below and
reinstall it from its own entry.

To read a machine's disks and MACs before it has an entry:

1. Boot the `New hardware` entry.
2. Open a shell from the installer's **Help** menu (**Enter shell**).
3. Run `lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN` and
   `cat /sys/class/net/*/address`.
4. Power off without installing.

## Add a host

1. Add the host's vars in `hosts.yml`, e.g.:

   ```yaml
   nuc3:
     install_profile: server
     install_disk_serial: S5GXNF0RA00000X
     install_disk_model: Samsung SSD 980 PRO 1TB
     install_machine_macs: ["1c:69:7a:00:00:01"]
   ```

   A disk in a USB enclosure may report the enclosure's serial, as
   `gknas`'s NVMe did in its old enclosure: any drive in that enclosure
   would match, so only the MACs pin the entry to the machine.
2. Run `just check`. Its `scripts/test-make-install-stick` renders every
   host's install from `hosts.yml` and checks it.
3. Rebuild the stick on `ws03`: `scripts/make-install-stick --write /dev/sdX`.

## How it works

- `scripts/make-install-stick` downloads the ISO, runs `install/render.py`
  and remasters the ISO with `xorriso`.
- `install/render.py` writes a cloud-init NoCloud seed per host to
  `/install/<host>/` on the stick (`user-data` holds the autoinstall
  config), and adds the GRUB entries. A host's entry boots with
  `autoinstall ds=nocloud;s=/cdrom/install/<host>/`.
- `install/disk-guard.sh` is the guard. Each host's autoinstall runs it
  first, as an early command. The storage config then picks the disk with
  `match: serial`, and the guard has already made sure that only one disk
  can match.
