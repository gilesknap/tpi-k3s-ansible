# Set up the cluster's directories on the NAS

:::{note}
This page describes the NAS as it runs today, on QTS. It is being replaced
by Ubuntu Server + ZFS configured by Ansible ({doc}`/how-to/nas-ubuntu-zfs`),
whose `nas` role creates these same directories, with the same owners and
modes, and exports the same paths. Until the switchover, this page is the
procedure.
:::

The NAS is a QNAP at 192.168.1.3. Everything the cluster keeps on it lives
in a handful of directories, and creating them is the one part of the
system done by hand: Ansible has no access to the NAS, and none is wanted.
The NAS also holds unrelated personal data (the media library and other
shares), and a playbook that can create and delete directories there
is one typo away from that data. So this page is a runbook to run on the
NAS itself, once per directory, and the cluster only ever mounts what
exists.

It has been run for every directory below; it is needed again only for a
new workload or a replaced NAS. The concepts (which workload uses which
kind of volume, and why) are in {doc}`/explanations/architecture/storage`.

## What the cluster mounts

The cluster mounts directories in two NFS exports of the NAS:

| Client-side path | Set by | Mounted by | Owner, mode |
|------------------|--------|------------|-------------|
| `/bigdisk/k8s-cluster/` | `nfs.cluster_share_path` | the `k8s-cluster-nfs` PV (claimed in the `backups` namespace); node02's etcd backup, at `/mnt/k8s-cluster` | `0755` |
| `/bigdisk/k8s-cluster/backups/grafana/`, `jellyfin/` (each with `weekly/`) | `additions/backups` | the Grafana and Jellyfin backup CronJobs | `0777` |
| `/bigdisk/k8s-cluster/backups/etcd/` (with `pre-upgrade/`) | `etcd_backup_dest_subdir` | node02's `k3s-etcd-backup` job, as root, so squashed to `65534` | `0777` |
| `/bigdisk/k8s-cluster/scrap-data/` | `additions/scrap` (`storage.data_dir`) | the `scrap-data-nfs` PV | `10001:10001`, `0750` |
| `/bigdisk/k8s-cluster/backups/scrap/` | `additions/scrap` (`storage.backups_dir`) | the `scrap-backups-nfs` PV | `10001:10001`, `0750` |
| `/bigdisk/k8s-cluster/backups/scrap-curated/` | `offsite_backup.backups.run_dirs` | the off-site backup, read-only (scrap backup runs kept by hand) | `10001:10001` |
| `/bigdisk/k8s-cluster/minecraft/` | `minecraft.store_subdir` | the Minecraft dashboard's store PV | `1000:1000`, `0755` |
| `/bigdisk/minecraft-archive/` | `minecraft.archive_path` | the dashboard's archive PV, read-only | no write bit at all |
| `/bigdisk/media/` | `jellyfin.media.nfs_path` | the `jellyfin-media-nfs` PV, read-only | as it was: the library predates the cluster |
| `/k8s-dynamic/` | `nfs_csi.share` | the `nfs-rwx` storage class | the share's own |
| `/k8s-dynamic/stable/` | `nfs_csi.stable_share` | the `nfs-stable` storage class (default); the dashboard and the off-site backup, read-only | same as `/k8s-dynamic/` |

All the variables are in `kubernetes-services/values.yaml`, except
`etcd_backup_dest_subdir` (`roles/etcd_backup/defaults/main.yml`). The
off-site backup ({ref}`offsite-backup`) reads `backups/`, the Minecraft
store, `/k8s-dynamic/stable` and the archive, all read-only.

The export squashes root (to `65534`) but not other users, so a pod's
writes arrive with its own uid. That is why each directory is owned by the
uid of the workload that writes it, and why the backup directories with
mixed writers (Grafana's uid `472`, Jellyfin's uid `122`, and the
root-squashed `65534` of older Grafana tarballs, which the jobs must still
prune) are `0777`.

The media library is the one directory here that the cluster did not
create and never writes: Jellyfin mounts it read-only three times over (the
PV, its access mode and the pod's mount).

## Why no new NFS export

On a stock Debian or Ubuntu NFS server the clean pattern is a drop-in under
`/etc/exports.d/`. QTS, the QNAP's OS, does not work that way:
`/etc/exports` is regenerated from the web UI's share configuration, there
is no `/etc/exports.d/`, and a hand edit is overwritten. So nothing here
touches the exports. The NAS already exports `bigdisk` read-write to
192.168.1.0/24, and the cluster's tree is a subdirectory of it.

### Two paths, same directory

| Path | Who uses it |
|------|-------------|
| `/share/CACHEDEV1_DATA/bigdisk/k8s-cluster` | commands run on the QNAP |
| `/bigdisk/k8s-cluster` | NFS clients: the PVs and node02's mount |

The client-side path works because the QNAP exports an NFSv4 pseudo entry,
`/share/NFSv=4/bigdisk`, with `nohide` and its own `fsid`, which makes
`bigdisk` a first-class path for NFSv4 clients. `k8s-dynamic` is a separate
QNAP shared folder, exported the same way.

## Prerequisites

- SSH to the QNAP as `admin` (or another account with a shell and the
  right to write under `/share/CACHEDEV1_DATA`).
- The QNAP is reachable at 192.168.1.3 from 192.168.1.0/24.

## The cluster tree and the backup directories

Run this once on the QNAP. It creates `k8s-cluster/` and the backup
directories of Grafana, Jellyfin and etcd.

```bash
# SSH to the QNAP as admin, then:

set -eu

# The real filesystem path of the existing /bigdisk export.
# (Client-side, Kubernetes sees this as /bigdisk/k8s-cluster.)
ROOT=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster

# 1. Create the cluster-owned directory tree.
#    The export uses root_squash (root → 65534) but not all_squash, so
#    writes from in-cluster pods arrive with their own UIDs. Leaf backup
#    dirs use 0777 so mixed writers (app UIDs, root-squashed jobs)
#    can all write.
mkdir -p "$ROOT"
mkdir -p "$ROOT/backups"
for app in grafana jellyfin; do
  mkdir -p "$ROOT/backups/$app"
  mkdir -p "$ROOT/backups/$app/weekly"
done
mkdir -p "$ROOT/backups/etcd/pre-upgrade"

chmod 0755 "$ROOT"
chmod 0755 "$ROOT/backups"
chmod -R 0777 "$ROOT/backups"/*

# 2. Verify.
ls -la "$ROOT" "$ROOT/backups"
```

The `chmod -R 0777 "$ROOT/backups"/*` is for the first setup only, while
`backups/` holds just these three directories. Run again later, it would
also open up `backups/scrap/`, whose runs are private to scrap's uid: on an
existing tree, `chmod` the one new directory instead.

From the devcontainer, confirm the new path is visible over NFS before
moving on:

```bash
# Spin a throwaway pod that mounts /bigdisk and lists k8s-cluster.
kubectl run nas-check --rm -it --restart=Never \
  --image=busybox:1.36 --overrides='
{
  "spec": {
    "volumes": [{
      "name": "nas",
      "nfs": { "server": "192.168.1.3", "path": "/bigdisk" }
    }],
    "containers": [{
      "name": "nas-check",
      "image": "busybox:1.36",
      "command": ["sh", "-c", "ls -la /mnt/k8s-cluster /mnt/k8s-cluster/backups"],
      "volumeMounts": [{ "name": "nas", "mountPath": "/mnt" }]
    }]
  }
}'
```

The listing shows the `backups` subtree.

## Rollback

:::{warning}
Only use this straight after first-time setup, while the tree is still empty.
Once the cluster is running, this tree holds every backup, scrap's live
data and the Minecraft store, and removing it destroys them.
:::

This runbook only adds a new directory, so rollback is to remove it once no
pods are consuming the tree. On the QNAP:

```bash
rm -rf /share/CACHEDEV1_DATA/bigdisk/k8s-cluster
```

## What this runbook does not do

- Read or write `/etc/exports` (QNAP-managed — editing breaks the UI).
- Create or modify any QNAP share or NFS export.
- Restart any NFS service.
- Touch any path outside `/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/`
  (the Minecraft archive and the dynamic volume share's `stable/` folder
  below are separate, deliberate steps).

## Adding new cluster-owned subfolders later

`mkdir` it under `/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/` by hand, and
give it the owner of the workload that will write to it. A directory needs
no repo change and no export change: everything the cluster writes on
`bigdisk` is inside this one subtree.

(nfs-csi-nas-share)=
## Dynamic volume share (NFS CSI)

The NFS CSI driver's storage classes provision volumes in a share of their
own, `nfs_csi.share` (`/k8s-dynamic`), not in `k8s-cluster/`. It is a
separate QNAP shared folder, `/share/CACHEDEV1_DATA/k8s-dynamic` on the NAS,
exported over NFS to 192.168.1.0/24. The driver creates one folder per
volume in it.

The `nfs-stable` class, the default ({doc}`/how-to/nfs-stable-paths`),
has its own share root inside it, `nfs_csi.stable_share`
(`/k8s-dynamic/stable`). It must exist before ArgoCD syncs the class, with
the same owner and mode as the share root, since the driver creates the
same kind of folders in both. A second cluster would need a `stable/` of
its own.

```bash
# SSH to the QNAP as admin, then:

set -eu
D=/share/CACHEDEV1_DATA/k8s-dynamic   # where the k8s-dynamic share lives
sudo mkdir -p "$D/stable"
sudo chown "$(stat -c '%u:%g' "$D")" "$D/stable"
sudo chmod "$(stat -c '%a' "$D")" "$D/stable"
ls -ldn "$D" "$D/stable"
```

Never delete or empty `stable/` while the Minecraft dashboard is deployed:
it holds the live world data, and the archives of deleted worlds.

(scrap-nas-directories)=
## scrap directories

scrap's two static NFS volumes ({doc}`/how-to/scrap`) mount these directories, so they
must exist before scrap is deployed. They must be owned by the uid/gid scrap
runs as (`10001`): the export squashes root, and NFS volumes ignore a pod's
`fsGroup`.

| Client-side path | Volume | Holds |
|------------------|--------|-------|
| `/bigdisk/k8s-cluster/scrap-data/` | `scrap-data-nfs` | `files/`, the preview cache, `litestream/` (the database's replica) |
| `/bigdisk/k8s-cluster/backups/scrap/` | `scrap-backups-nfs` | Daily backup runs, and `monthly/` |

```bash
# SSH to the QNAP as admin, then:

set -eu
ROOT=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster
mkdir -p "$ROOT/scrap-data" "$ROOT/backups/scrap"
chown 10001:10001 "$ROOT/scrap-data" "$ROOT/backups/scrap"
chmod 0750 "$ROOT/scrap-data" "$ROOT/backups/scrap"
```

Never delete or empty them while scrap is deployed: the replica in
`scrap-data` is the only up-to-date copy of the database. (An emptied
`scrap-data` beside existing backups makes scrap refuse to start, rather than
start empty.)

Backup runs kept by hand, outside scrap's own retention, go in a sibling
directory, `backups/scrap-curated/`, with the same owner. The off-site
backup uploads its runs like the others ({ref}`offsite-backup`):

```bash
mkdir -p "$ROOT/backups/scrap-curated"
chown 10001:10001 "$ROOT/backups/scrap-curated"
```

(minecraft-nas-directories)=
## Minecraft directories

The Minecraft dashboard ({doc}`/how-to/minecraft`) uses two static NFS
volumes on the `bigdisk` export (and a third, read-only, on the dynamic
volume share: {ref}`nfs-csi-nas-share`):

| Client-side path | Purpose | Access |
|------------------|---------|--------|
| `/bigdisk/minecraft-archive/` | Precious original world backups | **Read-only** — locked on the NAS and mounted read-only |
| `/bigdisk/k8s-cluster/minecraft/` | `backups/` (promoted), `snapshots/<world>/` (rolling), `dashboard/` (state) | Read-write, owned by uid/gid `1000` |

The archive sits **outside** `k8s-cluster/` on purpose: nothing that targets
the cluster-owned subtree (backup tooling, a future cleanup script, a
mistyped `rsync --delete`) can ever reach it. Moving a promoted backup into
the archive is always a deliberate manual step on the NAS.

Live world data does not live here: each world gets a dynamically
provisioned `nfs-stable` volume from the NFS CSI driver, in
`/k8s-dynamic/stable/minecraft/<world>-data`. That share root comes first
({ref}`nfs-csi-nas-share`).

```bash
# SSH to the QNAP as admin, then:

set -eu
BIGDISK=/share/CACHEDEV1_DATA/bigdisk

# 1. Writable store, owned by the uid/gid the dashboard and its Jobs run as.
mkdir -p "$BIGDISK/k8s-cluster/minecraft/backups" \
         "$BIGDISK/k8s-cluster/minecraft/snapshots" \
         "$BIGDISK/k8s-cluster/minecraft/dashboard"
chown -R 1000:1000 "$BIGDISK/k8s-cluster/minecraft"
chmod -R 0755 "$BIGDISK/k8s-cluster/minecraft"

# 2. Archive directory, outside k8s-cluster/. Populate it now (see below)
#    before locking it.
mkdir -p "$BIGDISK/minecraft-archive"
```

Populate the archive with the `ingest-archive.sh` script from the
[k3s-minecraft](https://github.com/gilesknap/k3s-minecraft) repository, as
described in {doc}`/how-to/minecraft`:

```bash
scripts/ingest-archive.sh "$BIGDISK/minecraft-archive" <drive-zips...>
```

Then make the archive read-only for everyone, including its owner:

```bash
chmod -R a-w "$BIGDISK/minecraft-archive"

# Verify — no file or directory should show a 'w' bit.
find "$BIGDISK/minecraft-archive" -perm /222 | head
```

This is the first of two locks: the dashboard chart also mounts the archive
with a read-only NFS mount, so a mistake in either layer alone cannot
modify the originals. To add files later, `chmod u+w` the directory, re-run
the ingest script, and lock it again.
