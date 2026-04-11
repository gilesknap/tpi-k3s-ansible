# 12. Drop Longhorn in Favour of Static Local PVs + NFS Backups

**Status:** Accepted

**Supersedes:** 0009 (workstation exclusion from Longhorn — no longer
relevant with Longhorn removed).

## Context

The cluster previously used Longhorn as its block-storage CSI provider for
six stateful PVCs (Supabase `db`/`storage`/`minio`, Grafana, Prometheus,
Open WebUI), totalling about 225Gi of live data. Two compounding problems
forced a rethink:

1. **`/rebuild-cluster` destroys all Longhorn data.** The decommission
   playbook wipes `/var/lib/longhorn` and `/var/lib/rancher`, and Longhorn's
   volume metadata lives in Kubernetes CRDs that are gone once the cluster
   is torn down. Every rebuild was therefore a total loss of Supabase,
   Grafana history, and Open WebUI chat state.
2. **No backup system.** Longhorn's built-in volume snapshots are
   node-local and vanish with the node. Longhorn-to-NFS backup targets
   exist but were never wired up, because the recovery story still
   required a Longhorn cluster on the other side.

Additionally, the RK1 nodes each have a 1TB NVMe sitting mostly unused
(OS + free space) and nuc2 has a 931GB `/home` disk mounted at `/home`,
so local high-quality storage is already paid for.

The NAS (`gknas`, `192.168.1.3`) hosts existing NFS shares for LLM models
(rkllama/llamacpp) and Supabase DB dumps, *plus unrelated personal shares*
(JellyFin library, files, etc.) that must not be touched. Any NAS change
has to respect that trust boundary.

## Decision

**Drop Longhorn entirely. Replace it with two orthogonal layers:**

1. **Per-node static local PVs** (`additions/local-storage/`). A
   `local-nvme` `StorageClass` with `provisioner: kubernetes.io/no-provisioner`,
   `volumeBindingMode: WaitForFirstConsumer`, and `reclaimPolicy: Retain`.
   Six static `PersistentVolume` objects — one per live Longhorn PVC —
   each pre-bound via `spec.claimRef: {namespace, name}` to the exact
   chart-generated PVC name, and pinned via `spec.nodeAffinity` to a
   specific node:

   | PVC | Node | On-disk path |
   |-----|------|---|
   | `supabase-db` | nuc2 | `/home/k8s-data/supabase-db` |
   | `supabase-storage` | nuc2 | `/home/k8s-data/supabase-storage` |
   | `supabase-minio` | nuc2 | `/home/k8s-data/supabase-minio` |
   | `storage-grafana-prometheus-0` | node03 | `/var/lib/k8s-data/grafana` |
   | `prometheus-grafana-prometheus-kube-pr-prometheus-...` | node02 | `/var/lib/k8s-data/prometheus` |
   | `open-webui` | node04 | `/var/lib/k8s-data/open-webui` |

   The `k8s_data_dirs` Ansible role creates these directories
   idempotently (part of the `servers` play), with owner/mode chosen to
   match each workload's pod `securityContext`. `pb_decommission.yml`
   **preserves** `/home/k8s-data` and `/var/lib/k8s-data` by default; a
   new opt-in flag `-e wipe_local_data=true` removes them for a genuine
   clean-slate rebuild.

2. **Per-app backup CronJobs writing to one NFS share on the NAS**
   (`additions/backups/`). A single cluster-owned subtree
   `/bigdisk/k8s-cluster/` hosts all cluster data the cluster reads or
   writes over NFS — LLM models, Supabase DB dumps, and the new backup
   targets (`backups/<app>/{,weekly}`). One static NFS `PV`/`PVC` covers
   the whole subtree; each CronJob mounts it with a workload-specific
   `subPath`. Daily + weekly schedules per app; retention is enforced
   in-job with `find -mtime`. Prometheus is deliberately excluded —
   metrics are reconstructible from re-scrape.

## Rejected alternatives

### Keep Longhorn, add a backup pipeline

Possible, but doesn't fix the fundamental problem: a rebuild destroys the
primary data store and the restore path would need a working Longhorn
cluster on the other side. Longhorn is also the single biggest source of
rebuild pain (iSCSI cleanup, stuck finalizers, multiple retry loops in
`pb_decommission.yml`), and removing it simplifies the teardown
significantly.

### `local-path-provisioner` instead of static PVs

`local-path-provisioner` is already the default StorageClass (bundled
with k3s), so in principle we could just point charts at it. Rejected
because its PVC→`hostPath` bindings live in **etcd** — they are lost
when the cluster is rebuilt. The new cluster's `local-path-provisioner`
would allocate a brand new `hostPath` for each PVC, not re-bind to the
existing on-disk data. Static PVs with `claimRef` pinning are the only
way to guarantee a PVC re-binds to the *same* directory after a rebuild.

### Ansible-managed NFS setup on the NAS

The NAS is a QNAP (QTS) hosting unrelated personal data. Giving Ansible
access to it would require a trust boundary we don't want, and QTS
regenerates `/etc/exports` from its web UI on every change, so any
Ansible-written configuration would be fragile. Decision: **NAS setup
is a documented manual runbook** (`docs/how-to/nas-setup.md`) the user
runs by hand on the NAS. The runbook creates `/bigdisk/k8s-cluster/` as
a subdirectory of the existing `/bigdisk` NFS export (which is already
`rw` to the cluster subnet), so no QTS config changes are needed at
all. Rollback = leave the repo on the old paths (which still exist
untouched on the NAS).

### Tar-out / copy-in migration

Rejected because the Longhorn data being left behind is recreatable:
Supabase runs its init migrations fresh, Grafana starts with empty
dashboards (we had no saved dashboards), Prometheus starts empty (fine),
Open WebUI starts empty (chat history was disposable). A one-time
fresh-start cost was deemed acceptable versus the effort of tar-dumping
Longhorn volumes and restoring them into raw hostPath directories with
the right ownership.

## Consequences

### Positive

- Stateful app data now **survives `/rebuild-cluster` by default.** A
  rebuild re-binds the existing local-nvme PVs to fresh chart-generated
  PVCs; Supabase Studio shows the same thoughts, Grafana shows the
  same dashboards, Open WebUI shows the same chat history.
- **Actual backup system exists.** Nightly CronJobs write to the NAS,
  retention is enforced automatically, restore recipes are documented
  in {doc}`../how-to/backup-restore`.
- **Decommission is simpler.** All Longhorn-specific teardown (volume
  detachment waits, finalizer stripping, CRD cleanup, iSCSI logout,
  `/var/lib/longhorn` wipe) is gone. `pb_decommission.yml` is shorter
  and faster.
- **`open-iscsi` no longer required** on cluster nodes.

### Negative

- **No replication.** Losing a node loses that node's live data until
  the NFS backup is restored. Mitigation: per-app pinning spreads blast
  radius across four nodes (prometheus→node02, grafana→node03,
  open-webui→node04, supabase trio→nuc2), and RPO is one day (matching
  the daily CronJob schedule).
- **New RWO `local-nvme` workloads must choose a host explicitly.** The
  StorageClass is `WaitForFirstConsumer` + static PVs, so a new PVC
  with no matching PV stays Pending until someone adds one. This is
  captured as a hard rule in `CLAUDE.md`.
- **NAS remains a single point of failure** for LLM models, Supabase
  DB dumps, and backup targets — unchanged from the previous design.
- **Manual NAS runbook must be run once** before the first rebuild on
  this plan. Documented in `docs/how-to/nas-setup.md`; the cluster
  cannot come up without it (rkllama/llamacpp/supabase-db-data PVs
  would fail to mount their new paths).
- **Supabase `db-data` NFS path changed** from `/bigdisk/OpenBrain` to
  `/bigdisk/k8s-cluster/supabase-dumps` — ADR 0006 is still accepted
  (NFS for the dump store), but its path is superseded by this ADR.

## References

- PR #321 — scaffolds (this ADR's infrastructure, no cutover)
- PR #NNN — cutover (this ADR, chart StorageClass flips + Longhorn removal)
- ADR 0006 — Supabase DB dump storage on NFS (path updated by this ADR)
- ADR 0009 — Longhorn workstation exclusion (superseded by this ADR)
- `docs/how-to/nas-setup.md` — manual NAS runbook
- `docs/how-to/backup-restore.md` — CronJob schedule + restore recipes
