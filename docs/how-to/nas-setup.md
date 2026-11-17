# The cluster's directories on the NAS

The NAS, `gknas` at 192.168.1.3, runs Ubuntu Server with ZFS, configured by
`pb_nas.yml` ({doc}`/how-to/nas-ubuntu-zfs`). Everything the cluster keeps
on it lives in a handful of directories, and the `nas` role creates every
one of them (`nas_directories` in `roles/nas/defaults/main.yml`), with the
owner and mode below. Nothing here is made by hand: to create them, or to
put back an owner or mode that has drifted, run

```bash
ansible-playbook pb_nas.yml --tags nas_datasets
```

The role creates directories but never empties or removes one, which
`just check` enforces ({doc}`/how-to/nas-ubuntu-zfs`). The cluster
playbooks never touch the NAS, and the cluster only ever mounts what
exists. The NAS also holds unrelated personal data (the media library and
the photo archive), which the cluster does not mount or only reads.

This page lists each directory and why it has its owner. The concepts
(which workload uses which kind of volume, and why) are in
{doc}`/explanations/architecture/storage`.

## What the cluster mounts

Each path is the same on the NAS and for NFS clients: the ZFS datasets are
mounted at the paths the cluster's volumes name.

| Path | Set by | Mounted by | Owner, mode |
|------|--------|------------|-------------|
| `/bigdisk/k8s-cluster/` | `nfs.cluster_share_path` | the `k8s-cluster-nfs` PV (claimed in the `backups` namespace); node02's etcd backup, at `/mnt/k8s-cluster` | `0:0`, `0755` |
| `/bigdisk/k8s-cluster/backups/grafana/` (with `weekly/`) | `additions/backups` | Grafana's backup CronJobs | `472:472`, `0755` |
| `/bigdisk/k8s-cluster/backups/jellyfin/` (with `weekly/`) | `additions/backups` | Jellyfin's backup CronJobs | `122:124`, `0755` |
| `/bigdisk/k8s-cluster/backups/etcd/` (with `pre-upgrade/`) | `etcd_backup_dest_subdir` | node02's `k3s-etcd-backup` job, as root, so squashed to `65534` | `65534:65534`, `0755` |
| `/bigdisk/k8s-cluster/scrap-data/` | `additions/scrap` (`storage.data_dir`) | the `scrap-data-nfs` PV | `10001:10001`, `0750` |
| `/bigdisk/k8s-cluster/backups/scrap/` | `additions/scrap` (`storage.backups_dir`) | the `scrap-backups-nfs` PV | `10001:10001`, `0750` |
| `/bigdisk/k8s-cluster/backups/scrap-curated/` | `offsite_backup.backups.run_dirs` | the off-site backup, read-only (scrap backup runs kept by hand) | `10001:10001`, `0750` |
| `/bigdisk/k8s-cluster/backups/config/cloudflare/` (with its parent) | none | dated copies of the Cloudflare OpenTofu state (encrypted) and `live.auto.tfvars`, copied in over ssh as `ansible` after each `just cf-apply`; read by the off-site backup | `1000:1000`, `0755` |
| `/bigdisk/k8s-cluster/minecraft/` (with `backups/`, `snapshots/`, `dashboard/`) | `minecraft.store_subdir` | the Minecraft dashboard's store PV | `1000:1000`, `0755` |
| `/bigdisk/minecraft-archive/` | `minecraft.archive_path` | the dashboard's archive PV, read-only | `0:0`, `0555`, its files with no write bit at all |
| `/bigdisk/media/` | `jellyfin.media.nfs_path` | the `jellyfin-media-nfs` PV, read-only | as it was: the library predates the cluster |
| `/k8s-dynamic/` | `nfs_csi.share` | the `nfs-rwx` storage class | `0:0`, `0777` |
| `/k8s-dynamic/stable/` | `nfs_csi.stable_share` | the `nfs-stable` storage class (default); the dashboard and the off-site backup, read-only | `0:0`, `0777` |

All the variables are in `kubernetes-services/values.yaml`, except
`etcd_backup_dest_subdir` (`roles/etcd_backup/defaults/main.yml`). The
off-site backup ({ref}`offsite-backup`) reads `backups/`, the Minecraft
store, `/k8s-dynamic/stable` and the archive, all read-only.

The `/bigdisk` exports squash root (to `65534`) but not other users, so a
pod's writes arrive with its own uid. That is why each directory is owned
by the uid of the workload that writes it: only that writer can add,
replace or prune files there, and the others (the off-site copy, which
reads `backups/` as `65534`) can still read them. Which hosts each export
admits, and how, is in {doc}`/how-to/nas-ubuntu-zfs`.

The media library is the one directory here that the cluster did not
create and never writes: Jellyfin mounts it read-only three times over (the
export, the PV's access mode and the pod's mount).

## Check a directory

On the NAS (as `ansible`, who has `sudo`):

```bash
ls -ldn /bigdisk/k8s-cluster /bigdisk/k8s-cluster/backups/* \
  /bigdisk/k8s-cluster/scrap-data /bigdisk/k8s-cluster/minecraft \
  /bigdisk/minecraft-archive /k8s-dynamic/stable
```

From the devcontainer, that the cluster sees it over NFS:

```bash
# Spin a throwaway pod that mounts the cluster share and lists it.
kubectl run nas-check --rm -it --restart=Never \
  --image=busybox:1.36 --overrides='
{
  "spec": {
    "volumes": [{
      "name": "nas",
      "nfs": { "server": "192.168.1.3", "path": "/bigdisk/k8s-cluster" }
    }],
    "containers": [{
      "name": "nas-check",
      "image": "busybox:1.36",
      "command": ["sh", "-c", "ls -la /mnt /mnt/backups"],
      "volumeMounts": [{ "name": "nas", "mountPath": "/mnt" }]
    }]
  }
}'
```

The listing shows the `backups` subtree.

## Adding a new directory

Add an entry to `nas_directories` (path, owner and mode: the uid of the
workload that will write it) and re-run
`ansible-playbook pb_nas.yml --tags nas_datasets`. A directory under
`/bigdisk/k8s-cluster/` needs no export change: everything the cluster
writes on `/bigdisk` is inside that one dataset. A new dataset is a new
entry in `nas_datasets` and, if the cluster mounts it, in `nas_nfs_exports`
too ({doc}`/how-to/nas-ubuntu-zfs`).

Removing an entry only stops the role managing the directory; it never
deletes it. Delete a directory by hand on the NAS, once nothing uses it and
you are sure.

(nfs-csi-nas-share)=
## Dynamic volume share (NFS CSI)

The NFS CSI driver's storage classes provision volumes in a share of their
own, `nfs_csi.share` (`/k8s-dynamic`, the `tank/k8s-dynamic` dataset), not
in `k8s-cluster/`. Its export does not squash root, since the driver
creates and archives the folders as root, one per volume.

The `nfs-stable` class, the default ({doc}`/how-to/nfs-stable-paths`),
has its own share root inside it, `nfs_csi.stable_share`
(`/k8s-dynamic/stable`). It must exist before ArgoCD syncs the class, with
the same owner and mode as the share root, since the driver creates the
same kind of folders in both; the `nas` role makes both. A second cluster
would need a `stable/` of its own.

Never delete or empty `stable/` while the Minecraft dashboard is deployed:
it holds the live world data, and the archives of deleted worlds.

(scrap-nas-directories)=
## scrap directories

scrap's two static NFS volumes ({doc}`/how-to/scrap`) mount these directories, so they
must exist before scrap is deployed. They are owned by the uid/gid scrap
runs as (`10001`): the export squashes root, and NFS volumes ignore a pod's
`fsGroup`.

| Path | Volume | Holds |
|------|--------|-------|
| `/bigdisk/k8s-cluster/scrap-data/` | `scrap-data-nfs` | `files/`, the preview cache, `litestream/` (the database's replica) |
| `/bigdisk/k8s-cluster/backups/scrap/` | `scrap-backups-nfs` | Daily backup runs, and `monthly/` |

Never delete or empty them while scrap is deployed: the replica in
`scrap-data` is the only up-to-date copy of the database. (An emptied
`scrap-data` beside existing backups makes scrap refuse to start, rather than
start empty.)

Backup runs kept by hand, outside scrap's own retention, go in a sibling
directory, `backups/scrap-curated/`, with the same owner. The off-site
backup uploads its runs like the others ({ref}`offsite-backup`).

(minecraft-nas-directories)=
## Minecraft directories

The Minecraft dashboard ({doc}`/how-to/minecraft`) uses two static NFS
volumes (and a third, read-only, on the dynamic volume share:
{ref}`nfs-csi-nas-share`):

| Path | Purpose | Access |
|------|---------|--------|
| `/bigdisk/minecraft-archive/` | Precious original world backups | **Read-only**: locked on the NAS, exported read-only and mounted read-only |
| `/bigdisk/k8s-cluster/minecraft/` | `backups/` (promoted), `snapshots/<world>/` (rolling), `dashboard/` (state) | Read-write, owned by uid/gid `1000` |

The archive is a dataset of its own, **outside** `k8s-cluster/`, on
purpose: nothing that targets the cluster-owned subtree (backup tooling, a
future cleanup script, a mistyped `rsync --delete`) can ever reach it.
Moving a promoted backup into the archive is always a deliberate manual
step on the NAS.

Live world data does not live here: each world gets a dynamically
provisioned `nfs-stable` volume from the NFS CSI driver, in
`/k8s-dynamic/stable/minecraft/<world>-data`. That share root comes first
({ref}`nfs-csi-nas-share`).

Populate the archive on the NAS itself (its export is read-only to every
host) with the `ingest-archive.sh` script from the
[k3s-minecraft](https://github.com/gilesknap/k3s-minecraft) repository, as
described in {doc}`/how-to/minecraft`, then lock it again:

```bash
# On the NAS
sudo chmod u+w /bigdisk/minecraft-archive
sudo scripts/ingest-archive.sh /bigdisk/minecraft-archive <drive-zips...>
sudo chmod -R a-w /bigdisk/minecraft-archive

# Verify: no file or directory should show a 'w' bit.
find /bigdisk/minecraft-archive -perm /222 | head
```

The archive has three locks: no write bit on the NAS, a read-only export,
and the dashboard chart's read-only mount, so a mistake in any one layer
alone cannot modify the originals.
