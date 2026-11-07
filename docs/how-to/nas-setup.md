# Set Up the Cluster NFS Tree on the NAS

This is a **one-time manual runbook** you run by hand on the NAS (a QNAP).
Ansible has no access to the NAS and this is by design: the NAS hosts
unrelated personal data (JellyFin libraries, Minecraft, Public) alongside
the cluster's NFS shares, and we don't want an ansible playbook anywhere
near it.

## Why this doesn't create a new NFS export

On a stock Debian/Ubuntu NFS server, the clean pattern would be to add a
drop-in file under `/etc/exports.d/` and reload exports. **QTS (the QNAP
OS) does not work this way** — `/etc/exports` is auto-regenerated from the
QNAP web UI's share configuration, there is no `/etc/exports.d/`, and
hand-editing `/etc/exports` is dangerous because the UI overwrites it.

The good news is we don't need a new export at all. Your QNAP already
exports `/share/CACHEDEV1_DATA/bigdisk` with read-write access to the
cluster subnet.

So this runbook **just creates a new subdirectory inside the existing
`bigdisk` export** — `bigdisk/k8s-cluster/`. No
export changes, no `/etc/exports` edits, no QNAP UI configuration. The
exact client-side vs server-side path mapping is covered under
[Two paths, same directory](#two-paths-same-directory) below.

## What we're creating

A single directory tree `bigdisk/k8s-cluster/` that contains **everything**
the cluster reads or writes over NFS:

- `backups/<app>/` and `backups/<app>/weekly/` — daily and weekly
  CronJob backup output (empty on first setup)
- `backups/etcd/` — the control plane's nightly age-encrypted etcd backup
  ({ref}`etcd-offsite-backup`), written by root on the control plane and
  so arriving as the root-squashed uid
- `scrap-data/` and `backups/scrap/` — scrap's data volume (files and the
  database's Litestream replica) and its backups (see
  {ref}`scrap-nas-directories` below)
- `minecraft/` — optional; the Minecraft dashboard's writable store (see
  {ref}`minecraft-nas-directories` below)

The optional Minecraft world **archive** is the one cluster-visible path
that deliberately lives *outside* this tree — see
{ref}`minecraft-nas-directories`.

### Two paths, same directory

Be aware of the two paths you'll see in this runbook — they are the same
physical directory, just viewed from different sides:

| Path                                        | Who uses it                         |
|---------------------------------------------|-------------------------------------|
| `/share/CACHEDEV1_DATA/bigdisk/k8s-cluster` | You, running commands on the QNAP   |
| `/bigdisk/k8s-cluster`                      | The Kubernetes NFS PV (client-side) |

The client-side path `/bigdisk/...` works because the QNAP exports a
separate NFSv4-pseudo entry `/share/NFSv=4/bigdisk` with `nohide` and
its own `fsid`, which makes `bigdisk` a first-class path for NFSv4
clients.

## Prerequisites

- You can SSH to the QNAP as `admin` (or another account with shell
  access and rights to write under `/share/CACHEDEV1_DATA`).
- The QNAP is reachable at `192.168.1.3` from the cluster subnet.

## One-time setup

Run this once on the QNAP. It creates the directory tree.

```bash
# SSH to the QNAP as admin, then:

set -eu

# The real filesystem path of the existing /bigdisk export.
# (Client-side, Kubernetes sees this as /bigdisk/k8s-cluster.)
ROOT=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster

# 1. Create the cluster-owned directory tree.
#    The export uses root_squash (root → 65534) but not all_squash, so
#    writes from in-cluster pods arrive with their own UIDs. Leaf backup
#    dirs use 0777 so mixed writers (alpine=root-squashed, app UIDs)
#    can all write.
mkdir -p "$ROOT"
mkdir -p "$ROOT/backups"
for app in grafana; do
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

From the cluster devcontainer, confirm the new path is visible over NFS
before moving on:

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

You should see the `backups` subtree.

## Rollback

:::{warning}
Only use this straight after first-time setup, while the tree is still empty.
Once the cluster is running, this tree holds your backups and other workload
data, and removing it destroys them.
:::

This runbook only adds a new directory, so rollback is to remove it once no
pods are consuming the tree. On the QNAP:

```bash
rm -rf /share/CACHEDEV1_DATA/bigdisk/k8s-cluster
```

## What this runbook explicitly DOES NOT do

- Read or write `/etc/exports` (QNAP-managed — editing breaks the UI).
- Create or modify any QNAP share or NFS export.
- Restart any NFS service.
- Touch any path outside `/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/`
  (the optional Minecraft archive and the dynamic volume share's `stable/`
  folder below are separate, deliberate steps).

## Adding new cluster-owned subfolders later

Just `mkdir` under `/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/` by hand.
No repo change needed for directory additions, and no export changes
ever — everything the cluster writes lives inside a single subtree of
the existing `bigdisk` export.

(nfs-csi-nas-share)=
## Dynamic volume share (NFS CSI)

The NFS CSI driver's storage classes provision volumes in a share of their
own, `nfs_csi.share` (default `/k8s-dynamic`), not in `k8s-cluster/`. On a
QNAP it is a separate shared folder exported over NFS to the cluster subnet,
for example `/share/CACHEDEV1_DATA/k8s-dynamic` on the NAS. The driver
creates one folder per volume in it.

The `nfs-stable` class, the default ({doc}`nfs-stable-paths`),
has its own share root inside it, `nfs_csi.stable_share` (default
`/k8s-dynamic/stable`). Create it once, before Argo CD syncs the class,
with the same owner and mode as the share root, since the driver creates the
same kind of folders in both. Give each cluster its own.

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

scrap's two static NFS volumes ({doc}`scrap`) mount these directories, so they
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

(minecraft-nas-directories)=
## Minecraft directories (optional)

Only needed if you enable the Minecraft dashboard ({doc}`minecraft`). It uses
two static NFS volumes on the existing `bigdisk` export (and a third, read-only,
on the dynamic volume share: {ref}`nfs-csi-nas-share`):

| Client-side path | Purpose | Access |
|------------------|---------|--------|
| `/bigdisk/minecraft-archive/` | Precious original world backups | **Read-only** — locked on the NAS and mounted read-only |
| `/bigdisk/k8s-cluster/minecraft/` | `backups/` (promoted), `snapshots/<world>/` (rolling), `dashboard/` (state) | Read-write, owned by uid/gid `1000` |

The archive sits **outside** `k8s-cluster/` on purpose: nothing that targets
the cluster-owned subtree — backup tooling, a future cleanup script, a
mistyped `rsync --delete` — can ever reach it. Moving a promoted backup into
the archive is always a deliberate manual step on the NAS.

Live world data does not live here: each world gets a dynamically
provisioned `nfs-stable` volume from the NFS CSI driver, in
`<nfs_csi.stable_share>/minecraft/<world>-data`. Create that share root
first ({ref}`nfs-csi-nas-share`).

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

# 2. Archive directory — outside k8s-cluster/. Populate it now (see below)
#    before locking it.
mkdir -p "$BIGDISK/minecraft-archive"
```

Populate the archive with the `ingest-archive.sh` script from the
[k3s-minecraft](https://github.com/gilesknap/k3s-minecraft) repository, as
described in {doc}`minecraft`:

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
