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
cluster subnet, and it is already mounted by rkllama, llamacpp, and
the supabase db-dump PV.

So this runbook **just creates a new subdirectory inside the existing
`bigdisk` export** — `bigdisk/k8s-cluster/` — and populates it. No
export changes, no `/etc/exports` edits, no QNAP UI configuration. The
exact client-side vs server-side path mapping is covered under
[Two paths, same directory](#two-paths-same-directory) below.

## What we're creating

A single directory tree `bigdisk/k8s-cluster/` that contains **everything**
the cluster reads or writes over NFS:

- `models/` — LLM model files consumed by rkllama and llamacpp
  (populated from the existing `bigdisk/LMModels/` tree)
- `supabase-dumps/` — Supabase database dumps
  (populated from the existing `bigdisk/OpenBrain/` tree)
- `backups/<app>/` and `backups/<app>/weekly/` — daily and weekly
  CronJob backup output (empty on first setup)

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
clients. This is how rkllama and llamacpp already mount their models.

## Prerequisites

- You can SSH to the QNAP as `admin` (or another account with shell
  access and rights to write under `/share/CACHEDEV1_DATA`).
- The QNAP is reachable at `192.168.1.3` from the cluster subnet. Already
  true — rkllama / llamacpp / supabase-db-data all currently mount from
  there.
- Enough free space on the volume to duplicate the existing `LMModels`
  tree. Check with `du -sh /share/CACHEDEV1_DATA/bigdisk/LMModels` before
  starting; compare against `df -h /share/CACHEDEV1_DATA`.

## Phase 1 — one-time setup + initial data copy

Run this once on the QNAP. It creates the directory tree and copies the
existing LLM models and Supabase db dumps into their new homes. The old
paths (`bigdisk/LMModels` and `bigdisk/OpenBrain`) are **preserved
untouched** — they remain available as a rollback safety net. Do not
delete them until you are certain the new setup is working.

```bash
# SSH to the QNAP as admin, then:

set -eu

# The real filesystem path of the existing /bigdisk export.
# (Client-side, Kubernetes sees this as /bigdisk/k8s-cluster.)
ROOT=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster

# 1. Create the cluster-owned directory tree.
#    The export uses root_squash (root → 65534) but not all_squash, so
#    writes from in-cluster pods arrive with their own UIDs. Leaf backup
#    dirs use 0777 so mixed writers (alpine=root-squashed, postgres=999)
#    can all write. Models/supabase-dumps are read-mostly so 0755 is fine.
mkdir -p "$ROOT"
mkdir -p "$ROOT/models"
mkdir -p "$ROOT/supabase-dumps"
mkdir -p "$ROOT/backups"
for app in supabase-db supabase-storage supabase-minio grafana open-webui; do
  mkdir -p "$ROOT/backups/$app"
  mkdir -p "$ROOT/backups/$app/weekly"
done

chmod 0755 "$ROOT" "$ROOT/models" "$ROOT/supabase-dumps"
chmod 0755 "$ROOT/backups"
chmod -R 0777 "$ROOT/backups"/*

# 2. Initial data copy — bulk-populate models/ and supabase-dumps/ from
#    the existing paths. cp -a preserves perms/times. rsync is also
#    available on QTS if you'd rather see progress:
#      rsync -a --info=progress2 <src>/ <dst>/
#
#    Safe to run while the cluster is using the old paths:
#    - LLM models are read-only in practice
#    - Supabase dumps are written once/day by a CronJob; worst case a
#      dump written during the copy is missed and will be picked up by
#      Phase 2.
cp -a /share/CACHEDEV1_DATA/bigdisk/LMModels/.  "$ROOT/models/"
cp -a /share/CACHEDEV1_DATA/bigdisk/OpenBrain/. "$ROOT/supabase-dumps/"

# 3. Verify — sizes should match within a few MB of metadata.
echo "--- Old vs new sizes ---"
du -sh /share/CACHEDEV1_DATA/bigdisk/LMModels  "$ROOT/models"
du -sh /share/CACHEDEV1_DATA/bigdisk/OpenBrain "$ROOT/supabase-dumps"
echo "--- Tree ---"
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

You should see the `models`, `supabase-dumps` and `backups` subtrees.

## Phase 2 — final sync before rebuild

Re-run this right before `/rebuild-cluster`. It catches any deltas since
Phase 1 — in practice the only moving parts are the daily Supabase dump
and any newly-downloaded LLM models. `rsync --delete` turns the target
into a true mirror of the source, so anything removed upstream is
removed from the new share too.

```bash
set -eu
ROOT=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster

rsync -a --delete --info=progress2 \
  /share/CACHEDEV1_DATA/bigdisk/LMModels/  "$ROOT/models/"

rsync -a --delete --info=progress2 \
  /share/CACHEDEV1_DATA/bigdisk/OpenBrain/ "$ROOT/supabase-dumps/"

echo "Final sync complete. Safe to run /rebuild-cluster now."
```

If the QNAP doesn't have `rsync` on the default PATH, either use its full
path (`/usr/bin/rsync` on most QTS builds) or fall back to `cp -a`.

## Rollback

The old paths are never touched by this runbook, so rollback is:

1. Revert `kubernetes-services/values.yaml` — point `rkllama.nfs.path`,
   `llamacpp.nfs.path` and `supabase.nfs.path` back at `/bigdisk/LMModels`,
   `/bigdisk/LMModels/cuda` and `/bigdisk/OpenBrain` respectively.
2. Re-sync ArgoCD. rkllama / llamacpp / supabase-db-data will re-bind to
   the OLD paths and work exactly as before.
3. Only once no pods are consuming the new tree, on the QNAP:

   ```bash
   rm -rf /share/CACHEDEV1_DATA/bigdisk/k8s-cluster
   ```

   Note that `bigdisk/LMModels` and `bigdisk/OpenBrain` are untouched
   by the rollback — the copy was additive.

## What this runbook explicitly DOES NOT do

- Read or write `/etc/exports` (QNAP-managed — editing breaks the UI).
- Create or modify any QNAP share or NFS export.
- Restart any NFS service.
- Touch any path outside `/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/`.
- Delete data from the old paths.

## Adding new cluster-owned subfolders later

Just `mkdir` under `/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/` by hand.
No repo change needed for directory additions, and no export changes
ever — everything the cluster writes lives inside a single subtree of
the existing `bigdisk` export.
