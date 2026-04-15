# Tutorials

Step-by-step guides that walk you through setting up a K3s cluster from scratch.

## Why the cluster is built this way

Before you start installing, two design choices shape everything the
tutorials ask you to do. Neither is the only way to run K3s at home —
they are the choices this repo made, and knowing *why* will save you
from fighting the defaults later.

**Static local-nvme PVs, one per stateful workload.** Each stateful
service (Supabase DB, Grafana, Prometheus, Open WebUI, …) gets a
hand-declared `PersistentVolume` backed by a plain directory on a
specific node — e.g. `/home/k8s-data/supabase-db` on `nuc2`. The PV
is pre-bound to its PVC via `claimRef` and pinned to its node via
`nodeAffinity`, so the pod *must* land there and the data *must*
survive a rebuild. No CSI driver, no replicas, no block-storage
cluster. The trade-off is explicit: you accept that losing a
worker's disk loses that workload until the disk is restored, in
exchange for far simpler operations, lower RAM/CPU overhead on small
nodes, and data that transparently survives
`ansible-playbook pb_all.yml`. The full rationale is in
{doc}`explanations/decisions/0012-drop-longhorn`.

**Backups live on NFS, not in the cluster.** Point-in-time backups of
every stateful service are written by `CronJob`s to a single NFS tree
on a NAS. That NAS is set up **once, by hand**, via
{doc}`how-to/nas-setup` — Ansible has no access to it, by design,
because the NAS hosts mixed personal data. So the stateful-data
strategy has two halves: local PVs give you rebuild survival, and
NFS CronJobs give you off-cluster point-in-time restore.

**Pod-to-node pinning is deliberate.** Because each stateful PV is
tied to one node, the corresponding Deployment/StatefulSet must also
land on that node. The existing pinning — `prometheus→node02`,
`grafana→node03`, `open-webui→node04`, Supabase trio `→nuc2` — is
not an accident, and new RWO `local-nvme` workloads need to pick
their own host. This is called out in `CLAUDE.md` as a hard rule.

With that mental model in place, pick your install path:

- **{doc}`tutorials/ai-guided-setup`** — let Claude Code run the whole setup
  interactively. Fastest path if you have Claude Code installed.
- **{doc}`tutorials/getting-started-tpi`** — manual walkthrough for Turing Pi
  v2.5 boards (flashes the compute modules from the BMC).
- **{doc}`tutorials/getting-started-generic`** — manual walkthrough for any
  modern Linux servers already running an OS.

Each tutorial covers fork-and-clone, inventory, config, and running the
playbook. For the full list of every file a fork needs to touch, see
{doc}`how-to/fork-this-repo` — it is the canonical reference for
personalising the repo and is linked from each tutorial at the relevant
steps.

```{toctree}
:maxdepth: 1
:hidden:

tutorials/ai-guided-setup
tutorials/getting-started-tpi
tutorials/getting-started-generic
tutorials/common-setup
```
