# 13. scrap Runs on Any Node: Litestream on NFS

**Status:** Accepted

**Amends:** 0012 for scrap. Grafana and Prometheus keep their pinned local PVs.

## Context

scrap keeps everything in one SQLite database and a folder of files. Under ADR 0012 it lived on a
static `local-nvme` PV pinned to one node. If that node died, scrap stayed down until it came back,
or until a hand-written restore of the last nightly backup onto another node. That loses up to a
day of writes, and doing it in a hurry breaks the repo's GitOps rules.

The scrap chart has a mode for this, `litestream.enabled`, made for an install whose only storage
is NFS (scrap's ADR 46). The database moves to an emptyDir on the pod's node. A Litestream sidecar
replicates it to `/data/litestream` on the data volume, about once a second. `files/` stays on the
data volume. Each new pod starts with `scrap db-init`, which restores the replica. The init
container fails closed when the volume looks wrong: it never starts empty on a volume that has held
a database.

## Decision

Run scrap in that mode, with no nodeSelector and no affinity:

- **Data and backups on static NFS PVs** on the NAS: `scrap-data-nfs` at
  `<cluster share>/scrap-data`, and `scrap-backups-nfs` at `<cluster share>/backups/scrap`.
  - They are static, not `nfs-rwx`, so a rebuild re-binds the same directories.
  - db-init's safety rests on that. A fresh, empty data volume *and* backups folder look like a
    new install, so it would start empty.
- **Failover is one human step.**
  - `just node-fence <node>` adds the `node.kubernetes.io/out-of-service` taint to a node that is
    NotReady and confirmed powered off. Kubernetes then removes its pods. The `Recreate`
    Deployment starts scrap on another node, where db-init restores the replica.
  - Nothing in git changes.
- **Not automatic.** Without power fencing, a partitioned node that is still running keeps its
  scrap pod. Two Litestreams writing one replica corrupt it.
- **An off-NAS copy.** A nightly CronJob copies the newest complete backup run to a `local-nvme`
  PV on one node, and keeps 3.
- **The move is one sync**, ordered by sync waves:
  1. the static PVs and PVCs (wave -2);
  2. a one-off Job (wave -1) on the old volume's node. It backs up the live database, copies the
     old backup runs across, and restores into the empty NFS volume;
  3. the chart (wave 0). The new pod's db-init brings `/data/scrap.db` across.
  - If the Job fails, the sync stops there and the old pod keeps serving.
  - The old local PV and claim stay as a frozen copy.
  - `scripts/scrap-cutover-check` then lists any writes the frozen copy has that the live database
    lacks.
  - Then the Job is retired at once (`legacy.migrate: false`): until then a rebuild needs the old
    node.
- **Fix forward; revert only before the first write after cut-over.** Reverting later goes back to
  the frozen copy and drops every write made since.

## Consequences

- **Data loss on a node death:** about a second of writes. A clean stop or a drain loses none.
- **Recovery:** about 1–2 minutes after the fence.
- **The NAS is now a serving dependency for scrap, and holds every copy except the off-NAS one.**
  - If it is down, files cannot be read and replication stalls.
  - After 20 minutes the pod leaves its Service, so it stops taking writes it cannot protect.
  - The off-NAS copy is up to a day old.
- gc and the Claude passes run in the pod's `jobs` container, not as CronJobs. A failed run shows
  in that container's log, not as a failed Job.
- A restore uses `scrap restore --stage` from a one-off pod (see
  {doc}`../../how-to/backup-restore`). A plain restore would be undone by the next start.
- Writes made between the Job's backup and the old pod stopping (about a minute) are not in the
  new volume. They remain in the frozen copy, and the cut-over check lists them.
- Ingress and other single-replica services on the dead node still need the fence, or about
  5 minutes of taint-based eviction, before they move.

## References

- scrap ADR 46 (database on an emptyDir, replicated with Litestream) and its
  [deployment guide](https://gilesknap.github.io/scrap/main/how-to/deploy-kubernetes.html)
- {doc}`../../how-to/scrap`, {doc}`../../how-to/node-operations`
- [Non-graceful node shutdown](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/#non-graceful-node-shutdown)
