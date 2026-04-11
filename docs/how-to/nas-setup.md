# Set Up the Cluster NFS Share on the NAS

This is a **one-time manual runbook** you run by hand on the NAS. Ansible has
no access to the NAS and this is by design: the NAS hosts unrelated personal
data (JellyFin libraries, files, etc.) alongside the cluster's NFS shares,
and we don't want an ansible playbook anywhere near it.

The runbook creates `/bigdisk/k8s-cluster/` — a single new path that contains
**everything** the cluster reads or writes over NFS:

- `models/` — LLM model files consumed by rkllama and llamacpp
- `supabase-dumps/` — Supabase database dumps
- `backups/<app>/` — daily and weekly CronJob backup output

The runbook installs the NFS export as a drop-in (`/etc/exports.d/k8s-cluster.exports`)
rather than editing `/etc/exports`. The kernel NFS server auto-merges
everything under `/etc/exports.d/*.exports`, so existing shares are completely
untouched and rollback is a one-liner.

## Prerequisites

- You can SSH to the NAS as root (or via `sudo -i`).
- The NAS already runs `nfs-kernel-server` and serves at least one share
  successfully. (It does if the current cluster's rkllama/llamacpp are working.)
- `/bigdisk` exists on the NAS and has enough free space to duplicate the
  existing `LMModels` tree (rsync of the whole models directory).
- Cluster nodes are all on `192.168.1.0/24`.

## Phase 1 — one-time setup + initial data copy

Run this once on the NAS. It creates the directory tree, installs the
export drop-in, reloads exports, and rsyncs the existing LLM models and
Supabase DB dumps from their old paths into the new share.

The old paths (`/bigdisk/LMModels` and `/bigdisk/OpenBrain`) are **preserved
untouched** — they remain available as a rollback safety net. Do not delete
them until you are certain the new setup is working in production.

```bash
set -euo pipefail

# 1. Create the cluster-owned directory tree. Owned by nobody:nogroup
#    (UID/GID 65534) to match all_squash in the export.
install -d -o 65534 -g 65534 -m 0755 /bigdisk/k8s-cluster
install -d -o 65534 -g 65534 -m 0755 /bigdisk/k8s-cluster/models
install -d -o 65534 -g 65534 -m 0755 /bigdisk/k8s-cluster/supabase-dumps
install -d -o 65534 -g 65534 -m 0755 /bigdisk/k8s-cluster/backups
for app in supabase-db supabase-storage supabase-minio grafana open-webui; do
  install -d -o 65534 -g 65534 -m 0755 "/bigdisk/k8s-cluster/backups/${app}"
  install -d -o 65534 -g 65534 -m 0755 "/bigdisk/k8s-cluster/backups/${app}/weekly"
done

# 2. Install the NFS export as a drop-in file. nfs-kernel-server auto-merges
#    /etc/exports.d/*.exports with /etc/exports — we only write to the
#    drop-in, so /etc/exports is never touched.
cat > /etc/exports.d/k8s-cluster.exports <<'EOF'
# Managed: written by docs/how-to/nas-setup.md from the k3s-ansible repo.
# Rollback: rm /etc/exports.d/k8s-cluster.exports && exportfs -ra
/bigdisk/k8s-cluster 192.168.1.0/24(rw,sync,no_subtree_check,root_squash,all_squash,anonuid=65534,anongid=65534,sec=sys)
EOF
chmod 0644 /etc/exports.d/k8s-cluster.exports

# 3. Reload exports.
exportfs -ra

# 4. Initial data copy. Uses rsync -a (preserve perms/times) +
#    --info=progress2 for a running total. The old paths remain untouched.
#    These rsyncs are safe to run while the cluster is still using the old
#    paths:
#    - LLM models are read-only in practice
#    - Supabase dumps are written once/day by a CronJob; worst case a dump
#      written during rsync is missed and will be picked up by Phase 2
rsync -a --info=progress2 /bigdisk/LMModels/  /bigdisk/k8s-cluster/models/
rsync -a --info=progress2 /bigdisk/OpenBrain/ /bigdisk/k8s-cluster/supabase-dumps/

# 5. Normalise ownership on the copied content. rsync preserves source
#    perms, which may not match the anon UID used by all_squash.
chown -R 65534:65534 /bigdisk/k8s-cluster/models /bigdisk/k8s-cluster/supabase-dumps

# 6. Verify.
echo "--- Current exports (should include /bigdisk/k8s-cluster) ---"
showmount -e localhost
echo "--- /etc/exports mtime (should be unchanged from before this run) ---"
stat -c '%y %n' /etc/exports
echo "--- New drop-in ---"
cat /etc/exports.d/k8s-cluster.exports
echo "--- Sizes of copied trees ---"
du -sh /bigdisk/LMModels /bigdisk/k8s-cluster/models
du -sh /bigdisk/OpenBrain /bigdisk/k8s-cluster/supabase-dumps
```

From any cluster node, confirm the export is visible:

```bash
showmount -e gknas
# Should show /bigdisk/k8s-cluster 192.168.1.0/24 alongside the existing
# shares (LMModels, OpenBrain, JellyFin, etc.) — confirm the existing
# exports are still listed.
```

## Phase 2 — final sync before rebuild

Re-run this any number of times. It catches any deltas since Phase 1 — in
practice the only moving parts are the daily Supabase dump and any
newly-downloaded LLM models. `--delete` turns the target into a true mirror
of the source, so anything removed upstream is removed from the new share.

Run immediately before `/rebuild-cluster` to minimise the window in which
new dumps could be missed.

```bash
set -euo pipefail

rsync -a --delete --info=progress2 /bigdisk/LMModels/  /bigdisk/k8s-cluster/models/
rsync -a --delete --info=progress2 /bigdisk/OpenBrain/ /bigdisk/k8s-cluster/supabase-dumps/
chown -R 65534:65534 /bigdisk/k8s-cluster/models /bigdisk/k8s-cluster/supabase-dumps

echo "Final sync complete. Safe to run /rebuild-cluster now."
```

## Rollback

The old paths are never touched by this runbook, so rollback is:

1. Revert `kubernetes-services/values.yaml` — point `rkllama.nfs.path`,
   `llamacpp.nfs.path` and `supabase.nfs.path` back at `/bigdisk/LMModels`,
   `/bigdisk/LMModels/cuda` and `/bigdisk/OpenBrain` respectively.
2. Re-sync ArgoCD. rkllama / llamacpp / supabase-db-data will re-bind to
   the OLD paths and work exactly as before.
3. Only once no pods are consuming the new share, on the NAS:

   ```bash
   rm /etc/exports.d/k8s-cluster.exports
   exportfs -ra
   # Optionally, to reclaim space once you're sure you no longer need it:
   # rm -rf /bigdisk/k8s-cluster
   ```

## What this runbook explicitly DOES NOT do

- Read or write `/etc/exports`.
- Modify any existing share.
- Restart `nfs-kernel-server` (only reloads exports via `exportfs -ra`).
- Touch any path outside `/bigdisk/k8s-cluster/` and
  `/etc/exports.d/k8s-cluster.exports`.
- Delete data from the old paths.

## Adding new cluster-owned subfolders later

Add another `install -d` line by hand on the NAS. No repo change needed for
directory additions. Export path additions would require editing the drop-in
file.
