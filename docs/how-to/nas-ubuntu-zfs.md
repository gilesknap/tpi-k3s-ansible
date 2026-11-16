# Build or rebuild the NAS (Ubuntu Server + ZFS)

The NAS, `gknas` at 192.168.1.3, is a QNAP TS-253D (Celeron J4125, 32 GB
RAM, two bays, two 2.5GbE ports). It moved from QTS, QNAP's own OS, to
Ubuntu Server 26.04 with ZFS, configured by Ansible like the rest of the
estate. It is **not** a cluster node: `pb_nas.yml` configures it, separately
from `pb_all.yml`, and nothing in `pb_all.yml` reaches it.

:::{note}
This page describes the NAS and how to build it again from bare metal.
{doc}`/how-to/nas-setup` lists the directories the cluster mounts on it.
Its notes on QTS describe the move from it.
:::

## What is on it

| Disk | Where | Holds |
|------|-------|-------|
| Fanxiang 256 GB NVMe, in a USB enclosure on a rear USB 2 port | The OS disk (later moved to an x4 PCIe adapter: the same disk, so no reinstall; only the boot order changes) | Ubuntu Server |
| Two Samsung 870 QVO 4 TB SSDs, in the bays | ZFS pool `tank`, a mirror | Everything the NAS serves |
| LaCie 4 TB USB drive, front USB 3 port | ZFS pool `backup`, one disk | A nightly copy of every dataset of `tank` |
| The internal DOM | Not used | QTS's firmware (still there: see the migration's back-out) |

Both pools have `ashift=12`, `compression=lz4`, `atime=off`, `xattr=sa`,
`acltype=posixacl` and `overlay=off` (a dataset never mounts over a directory
with files in it). The datasets keep the paths the cluster already mounts, so
no PersistentVolume changes:

| Dataset | Mountpoint | Exported | Used by |
|---------|------------|----------|---------|
| `tank/bigdisk` | `/bigdisk` | read-write, `ws03` only | parent of the four below |
| `tank/bigdisk/k8s-cluster` | `/bigdisk/k8s-cluster` | read-write | the backups, scrap's data and the Minecraft store ({doc}`/how-to/nas-setup` lists each directory) |
| `tank/bigdisk/media` | `/bigdisk/media` | read-write to `ws03`, **read-only** to the nodes | the Jellyfin library |
| `tank/bigdisk/minecraft-archive` | `/bigdisk/minecraft-archive` | **read-only** | the Minecraft dashboard's archive |
| `tank/bigdisk/Photos-Archive` | `/bigdisk/Photos-Archive` | read-write, `ws03` only | the photo archive |
| `tank/k8s-dynamic` | `/k8s-dynamic` | read-write, root not squashed | the NFS CSI driver's `nfs-rwx` and `nfs-stable` volumes (the Minecraft worlds) |
| `tank/Minecraft` | `/Minecraft` | read-write, `ws03` only | the pre-cluster Minecraft share |

The list is `nas_datasets` in `roles/nas/defaults/main.yml`
({doc}`/reference/variables`). Adding an entry and re-running the playbook
creates the dataset; removing one never destroys anything.

## How the exports differ from QTS

Every consumer mounts NFS 4.1 by the paths above (`vers=4.1` or `nfsvers=4.1`
on each PV and storage class, and on `node02`'s etcd backup mount). QTS served
those paths from an NFSv4 pseudo-root (`/share/NFSv=4/bigdisk`); Ubuntu
exports the real directories, which are the same paths, so the clients see no
difference.

| | QTS | Ubuntu |
|---|-----|--------|
| Who may mount | `bigdisk`: read-write to `192.168.1.0/24`, read-only to everyone (`*`); `k8s-dynamic`: read-write to `192.168.1.0/24` Only the six cluster hosts, by IP: `ws03` (.10), `node02` to `node04` (.82 to .84), `nuc1` (.91), `nuc2` (.92); nothing to anyone else. The nodes get only what the cluster mounts (`k8s-cluster`, `k8s-dynamic`, and `media` and `minecraft-archive` read-only); `/bigdisk`, `Photos-Archive` and `/Minecraft` are `ws03`'s alone |
| Root | `bigdisk`: `root_squash` to 65534; `k8s-dynamic`: `no_root_squash` | The same |
| Other uids | Not squashed | Not squashed: a pod's writes keep its uid (scrap's 10001, the dashboard's 1000, Grafana's 472, Jellyfin's 122) |
| Writes | `bigdisk`: `sync`; `k8s-dynamic`: `async` | The same |
| `minecraft-archive` | Read-write over NFS (read-only only by mode and the PV) | Read-only in the export too |
| One filesystem? | Yes: `bigdisk` and `k8s-dynamic` were one ext4 volume | No: each dataset is its own filesystem and its own export. A move between datasets is a copy, not a rename |

`nas_nfs_clients` in the role's defaults holds the client list, and each
entry of `nas_nfs_exports` can narrow it (`clients`) or make it read-only to
some hosts (`read_only_for`). A new node must be added there (and the
playbook re-run) before its pods can mount anything from the NAS. The nodes
still reach `/bigdisk/k8s-cluster` and `/bigdisk/media` without `/bigdisk`
itself being exported to them: the server's NFSv4 pseudo-root shows them the
path down to the exports they are given, and nothing else in it.

On QTS the backup directories were `0777`, because several uids write them.
Here each is owned by its one writer, mode `0755`: Grafana's backups by
`472`, Jellyfin's by `122:124`, and `etcd/` (with `pre-upgrade/`) by `65534`,
which node02's root-run job is squashed to. Only that writer can add or
delete backups there (pruning older files of other owners included), and the
off-site copy, which reads `backups/` as `65534`, can still read them all.
`backups/scrap-curated/` becomes `0750`, scrap's alone, like its other
directories.

Two things follow from moving NAS:

- **File handles change.** A pod that held an NFS mount across the switchover
  has a stale handle and must be restarted. The migration stops every NFS
  user first, so this only matters for anything missed.
- **The NAS must keep its IPv4 address.** Every consumer names `192.168.1.3`
  and the exports admit clients by IPv4 address. A client that reaches the NAS
  by name over IPv6 (`gknas.lan` may get an AAAA record once Ubuntu takes a
  SLAAC address) is refused: use the address.

## Build the NAS from bare metal

You need: the NAS, a USB stick, the OS NVMe in its enclosure and the
devcontainer on `ws03`.

### 1. Install Ubuntu

The install is unattended. The autoinstall stick
(Ubuntu Server 26.04 live ISO plus an `autoinstall.yaml`) creates:

- hostname `gknas`, DHCP (the router reserves 192.168.1.3 for it);
- the `ansible` account with passwordless sudo, no password, and the keys in
  `pub_keys/ansible_rsa.pub` plus the Claude sandbox's key;
- the packages `smartmontools nvme-cli lm-sensors ethtool zfsutils-linux`;
- the whole of the 200 to 300 GB disk with model `Tech` (the NVMe's USB
  enclosure) as the OS disk. It refuses to install if any disk over 2 TB is
  attached, so the drive trays and the LaCie must be out.

1. Power the NAS off. Pull both drive trays and unplug the LaCie.
2. Plug in the NVMe enclosure (rear USB 2) and the install stick, power on,
   and choose the stick in the boot menu. The install runs on its own and
   reboots.
3. Remove the stick. In the firmware setup, put the NVMe first in the boot
   order, before the DOM (QTS).

The NAS has two 2.5GbE ports; the install takes DHCP on whichever is cabled.
The router's reservation for 192.168.1.3 is by MAC address, so cable the port
it names (`ip -br link` on the NAS shows each port's name and MAC).

### 2. Configure the OS, before the data disks go in

From the devcontainer:

```bash
ansible-playbook pb_nas.yml --tags known_hosts
ansible-playbook pb_nas.yml --tags nas_os,nas_fan
```

`nas_os` stops Ubuntu assembling the Linux RAID it would find on disks that
come from QTS (`AUTO -all` in `/etc/mdadm/mdadm.conf`), so do it before the
trays go in. `nas_fan` builds the `qnap8528` driver (see {ref}`nas-fans`).

### 3. Put the disks in and name them

Power off, insert both trays (and the LaCie, if it is to become the backup
pool), and power on. Then, on the NAS:

```bash
ls -l /dev/disk/by-id/ | grep -v -- -part
```

Set `nas_pool_disks` (the two `ata-Samsung_SSD_870_QVO_4TB_<serial>` paths)
and `nas_backup_pool_disks` (the LaCie's `usb-...` path) in
`roles/nas/defaults/main.yml`, through a pull request as usual.

### 4. Create the pools

Creating a pool destroys everything on its disks, so the role does it only
when told, and checks first. It refuses unless:

- the pool does not already exist, imported or on the disks (an existing pool
  is imported instead, which changes nothing);
- the disks are given by `/dev/disk/by-id/` path (two for the mirror);
- no partition of the disks is mounted or used as swap (never overridable);
- the disks are blank: no partition table, partitions or filesystem signature,
  unless `-e nas_force=true` is also given.

Nothing else in the role destroys data: no task destroys a pool, dataset or
snapshot (sanoid prunes only snapshots past their retention, and never the
held weekly, {ref}`nas-snapshot-hold`).
`scripts/check-no-destroy`, run by `just check`, fails if one does, if this
gating is removed, or if a cluster playbook targets the NAS.

```bash
# The main pool. Disks from QTS carry its RAID, so they need nas_force.
ansible-playbook pb_nas.yml -e nas_create_pool=true -e nas_force=true

# The backup pool, once the LaCie holds nothing that is needed.
ansible-playbook pb_nas.yml -e nas_create_backup_pool=true -e nas_force=true
```

Then the same run creates the datasets, the cluster's directories
(`nas_directories`: the directories of {doc}`/how-to/nas-setup`, the backup
directories owned by their writers as above),
the exports, the snapshot schedule and the health checks. Every later run is
plain `ansible-playbook pb_nas.yml`; `--check --diff` shows what it would
change.

### 5. Put the data back

From the backup pool or Drive: see {ref}`nas-recovery`.

### 6. Turn on monitoring

Set `nas.monitoring.enabled: true` in `kubernetes-services/values.yaml`
({ref}`nas-monitoring`) and merge it.

## Running it

- **Updates** install every night (unattended-upgrades, from `-security` and
  `-updates`), kernels included. The NAS never reboots itself, and kured does
  not manage it. When `/var/run/reboot-required` exists, reboot it by hand at
  a quiet time: the cluster's NFS volumes hang (`hard` mounts) until it is
  back, and then carry on.
- **The OS disk** is spared writes: the journal is in RAM only (lost on a
  reboot; capped at 128 MB), `/` is mounted `noatime`, and there is no swap.
- **Snapshots**: sanoid snapshots every dataset of `tank` hourly (kept 48),
  daily (30), weekly (8, on Mondays at 23:30) and monthly (12). A file can be
  read back from `<mountpoint>/.zfs/snapshot/<snapshot>/` on the NAS. The
  newest weekly snapshot of each dataset is held ({ref}`nas-snapshot-hold`).
- **The copy to the backup pool**: `nas-replicate.timer` runs `syncoid` at
  06:30, after the cluster's nightly backups, sending every dataset of `tank`
  to `backup/tank` (incrementally). The copies are read-only, mounted under
  `/srv/backup`, and sanoid keeps 60 daily and 24 monthly snapshots of them
  (and prunes the weeklies that arrive).
  `journalctl -u nas-replicate` shows the last run.
- **Scrubs**: `zfs-scrub-monthly@tank.timer` and `zfs-scrub-monthly@backup.timer`
  (Ubuntu's own cron scrub is turned off per pool with the
  `org.debian:periodic-scrub=disable` property).
- **SMART**: smartd watches every disk, with a short self-test daily and a
  long one on Saturdays.
- **The off-site copy** to Google Drive is unchanged: the cluster's
  `offsite-backup` CronJob reads the NAS over NFS ({ref}`offsite-backup`).

(nas-snapshot-hold)=
### The hold on the newest weekly snapshot

Each dataset sanoid snapshots (`nas_hold_datasets`: every dataset of `tank`
in `nas_datasets`, `Photos-Archive` included) keeps a ZFS *hold*, tag
`nas-keep` (`nas_hold_tag`), on its newest weekly snapshot. ZFS refuses to
destroy a held snapshot, so a mistyped `zfs destroy` of that snapshot fails,
and so does a `zfs destroy -r` of the dataset: ZFS destroys a dataset's
snapshots in one all-or-nothing batch before the dataset itself, so neither
the dataset nor any of its snapshots goes. (A child dataset with no held
snapshot, made by hand or too new to have a weekly, is not protected.) It
guards against accidents only. Root can release the
hold and then destroy (and `zfs destroy -d` marks a held snapshot to go as
soon as it is released); `zpool destroy` ignores holds altogether. The
backup pool, and the off-site copy, are what cover a deliberate attack.

`nas-hold.timer` runs `/usr/local/sbin/nas-hold` daily at 02:00
(`nas_hold_on_calendar`), after sanoid's Monday 23:30 weekly: it holds the
newest weekly first, then releases the tag from older snapshots, so a dataset
never goes without a held snapshot. Other tags are left alone, and running it
again changes nothing. The hold costs no space: sanoid keeps that snapshot
anyway. The received copies on the backup pool are not held (`zfs send` does
not carry holds).

sanoid prunes weeklies oldest first and only while more than `weekly` remain,
so it never tries to prune the newest one; the role refuses a weekly
retention below 1 for a held dataset. If sanoid ever met a held snapshot, its
destroy would fail and it would log `could not remove <snapshot>` and carry
on with the rest, trying again on each run.

To see or lift the holds by hand, on the NAS:

```bash
# Every snapshot of a dataset with its hold count, then the holds on one.
zfs list -t snapshot -d 1 -o name,userrefs tank/bigdisk/k8s-cluster
zfs holds tank/bigdisk/k8s-cluster@autosnap_<date>_weekly
# Release it, e.g. to destroy that snapshot on purpose.
sudo zfs release nas-keep tank/bigdisk/k8s-cluster@autosnap_<date>_weekly
```

The next run of `nas-hold` holds the newest weekly again: to keep a dataset
out for good, take it out of `nas_hold_datasets`.

(nas-monitoring)=
## Monitoring

node-exporter runs on the NAS on port 9100, with its ZFS collector (pool
states), the `smartmon` collector, and three textfile metrics files the role
adds: `nas_zpool.prom` (error counts and the last scrub, every 5 minutes),
`nas_replicate.prom` (the last copy to the backup pool) and `nas_hold.prom`
(`nas_zfs_held_snapshot_timestamp_seconds{dataset}`, the creation time of
each dataset's held weekly snapshot, and whether `nas-hold` last
succeeded).

With `nas.monitoring.enabled: true`, Prometheus scrapes it as job `nas`
(a static target, `nas.monitoring.targets`, like `kube-etcd`) and loads these
alerts:

| Alert | Fires when | Severity |
|-------|------------|----------|
| `NasDown` | the NAS has not been scraped for 10 minutes | critical |
| `NasZfsPoolNotOnline` | a pool is degraded, faulted or unavailable | critical |
| `NasZfsPoolErrors` | a pool has read, write or checksum errors | warning |
| `NasZfsScrubErrors` | the last scrub found errors | warning |
| `NasZfsScrubOverdue` | no scrub has finished for 40 days | warning |
| `NasDiskSmartUnhealthy` | a disk fails its SMART health check | warning |
| `NasPoolFillingUp` | `/bigdisk` is over 85% full | warning |
| `NasBackupPoolCopyStale` | the copy to the backup pool has not succeeded for 36 hours | warning |
| `NasZfsHoldStale` | a dataset has no held snapshot, or its held weekly is over 8 days old (a new dataset gets 8 days from its creation) | warning |
| `NasZfsHoldFailed` | the last `nas-hold` run failed | warning |

All of them reach ntfy ({doc}`/how-to/ntfy`): the critical ones by severity,
the warnings by name.

(nas-fans)=
## Fans and the embedded controller

QTS drives the fans through the TS-253D's embedded controller. On Ubuntu, the
community [qnap8528](https://github.com/0xGiddi/qnap8528) kernel module
exposes it through hwmon: fan speeds, PWM, temperatures, LEDs and buttons. The
role builds it with DKMS at a pinned commit (`nas_qnap_ec_commit`, a release
at least two weeks old), loads it with `skip_hw_check=true` (the TS-253D's EC
reports another chip ID) and DKMS rebuilds it for every new kernel.
`nas_qnap_ec_driver: false` leaves it out.

The module does not decide fan speeds. Check `sensors` after a boot: if the EC
keeps the fans at a sensible speed by itself, nothing more is needed. If not,
run `pwmconfig` on the NAS, and put the `/etc/fancontrol` it writes into
`nas_fancontrol_config`: the role then installs and enables `fancontrol`.

(nas-recovery)=
## Recovery

| What failed | Data lost | What to do |
|-------------|-----------|------------|
| One SSD | Nothing | Replace it: `zpool replace tank <old-by-id> <new-by-id>`, then update `nas_pool_disks` |
| The OS disk | Nothing | Install again (steps 1 and 2), insert the disks, run `ansible-playbook pb_nas.yml`: it imports both pools and configures the rest |
| Both SSDs, or the NAS | Up to a day, since the last copy to the backup pool | A new pool, then restore from the backup pool, below |
| The NAS and the LaCie | Up to a day of the cluster's backups and worlds; anything not sent off site | A new pool, then restore from Drive ({ref}`offsite-backup`) |

### Restore from the backup pool

On new hardware (or new SSDs), install and configure as in steps 1 to 3 with
the LaCie plugged in, then create only the main pool, so that the datasets do
not exist yet:

```bash
ansible-playbook pb_nas.yml --tags nas_pool -e nas_create_pool=true -e nas_force=true
```

On the NAS, send each top-level dataset back from the backup pool, with every
snapshot:

```bash
for ds in bigdisk k8s-dynamic Minecraft; do
    sudo syncoid --recursive --no-sync-snap "backup/tank/$ds" "tank/$ds"
done
```

At USB 3 speeds (100 to 150 MB/s from the LaCie), 1.8 TB takes about four
hours; `k8s-cluster` and `k8s-dynamic`, which the cluster needs first, are
small, so send `bigdisk/k8s-cluster` and `k8s-dynamic` first if the cluster
is waiting. Then run the whole playbook, which sets the datasets' mountpoints
and properties, mounts them and starts the NFS server:

```bash
ansible-playbook pb_nas.yml
```

The nightly copy then carries on incrementally from the snapshots both pools
share.

### Restore from Drive

With no backup pool either, run the playbook with `-e nas_create_pool=true`:
it creates the datasets and the cluster's empty directory tree with the right
owners. Then restore the backups, the Minecraft store and worlds, and scrap
from Drive as {ref}`offsite-backup` describes. The media library, the photo
archive and the other shares are not in the cluster's off-site copy (the
photo archive has its own copy on Drive).
