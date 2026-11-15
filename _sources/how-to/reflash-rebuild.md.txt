# Re-flash and rebuild

Recovery and rebuild operations for this cluster's nodes: re-flashing an RK1,
reinstalling K3s, re-running one stage of the playbook, and the full
decommission and rebuild. For a lost control plane with a usable etcd
backup, use {doc}`/how-to/recover-control-plane` instead: it is faster and
keeps the cluster's state.

`pb_all.yml` is idempotent: it skips every step that is already done. The
force flags below override that.

| Flag | Effect |
|------|--------|
| `-e do_flash=true` | Enables the `flash` play, which flashes only the Turing Pi nodes that don't answer SSH. On an RK1 it never wipes an NVMe that has a partition table: the play stops and asks for `flash_force`. |
| `-e flash_force=true` | Re-flashes the Turing Pi nodes in the limit even if they are running: erases the eMMC and, on an RK1, the NVMe. Implies `do_flash`. |
| `-e k3s_force=true` | Uninstalls and reinstalls K3s on the nodes in the limit. On `node02` that discards etcd. |
| `-e wipe_local_data=true` | `pb_decommission.yml` only: also deletes `/home/k8s-data` and `/var/lib/k8s-data`. |

Flashing applies only to the RK1s (`node02`, `node03`, `node04`), through
the BMC `turingpi`. `nuc1`, `nuc2` and `ws03` are reinstalled by hand from
an Ubuntu installer, then joined as in {doc}`/how-to/node-operations`.

:::{important}
Always give a `--limit` when flashing, and include `turingpi`: the flash
runs on the BMC. Without a limit, `flash_force` re-flashes every node on
the board, and `do_flash` flashes any that happens not to answer SSH.
:::

## The RK1 rules

An RK1's root filesystem and its `local-nvme` PV data share one NVMe, so
a re-flash is not a routine operation:

- **Plain `do_flash` never wipes an NVMe that has a partition table.** It
  flashes the eMMC of a node that does not answer SSH, then stops, with the
  node powered off, if the NVMe may hold a working install.
- **`flash_force` wipes the NVMe.** It is a fresh install: everything on
  the node is lost, including the directories under `/var/lib/k8s-data`.
  Today that matters for `node04`, which holds Prometheus's and Grafana's
  data. `node02` and `node03` hold no local PV.
- **Get the owner's go-ahead** before re-flashing an RK1 that carries a
  `local-nvme` PV, and say that the data goes with it. Grafana's database
  has a nightly backup on the NAS ({doc}`/how-to/backup-restore`);
  Prometheus's metric history has none.
- **Nothing else writes to the first 16 MiB of an RK1's eMMC**, where
  U-Boot lives. Only `tpi flash` of the staging image built by
  `roles/flash` does. No `dd`, `mkfs` or partitioning there by hand.
- **Re-flashing `node02` destroys etcd.** Follow
  {doc}`/how-to/recover-control-plane`, which re-flashes it and stops
  before the `k3s` tag.

{doc}`/explanations/ansible-roles` explains the two-stage install (a staging
OS on the eMMC, then Ubuntu written to the NVMe) and why each rule exists.

## Re-flash one RK1

Check `local_storage` in `kubernetes-services/values.yaml` for the node
first. If it holds a PV, move it ({ref}`move-a-local-nvme-pv`) or accept
the loss. Then drain the node and re-flash it:

```bash
kubectl drain node03 --ignore-daemonsets --delete-emptydir-data
ansible-playbook pb_all.yml --limit turingpi,node03 -e flash_force=true
kubectl uncordon node03
```

With no `--tags`, the run carries on through `known_hosts`, `servers` and
`k3s`: the node gets Ubuntu on its NVMe, a dist-upgrade and its K3s agent
back. It takes about 27 minutes. The node gets new SSH host keys, which the
`known_hosts` play records. The old Node object is `NotReady` by the time
the `k3s` play reaches it, so the role deletes it and the node registers
afresh, uncordoned; the `uncordon` above is for a run that stopped early.

(rk1-reflash-timings)=
Where the time goes, from one clean run on node02 in November 2026 with
the image already cached and on the BMC:

| Stage | Time |
|-------|------|
| Check the cached image and its copy on the BMC | 0.5 min |
| `tpi flash` of the eMMC | 10.3 min |
| Seed the staging OS and wipe the NVMe from U-Boot | 1.3 min |
| Staging OS boots and answers SSH | 0.5 min |
| Write the image to the NVMe and verify it | 4 min |
| Reboot into the NVMe install, cloud-init | 0.6 min |
| Dist-upgrade (`update_packages`) | 6.5 min |
| K3s install and join | 1.5 min |

Ubuntu is up on the NVMe about 18 minutes after `tpi flash` starts, and
the node has rejoined K3s about 27 minutes after the run starts. A first
run with no cached image also builds it, which needs about 6 GB free in
`/tmp` on the controller.

For a node that is dead rather than misbehaving (it does not answer SSH),
`-e do_flash=true` is enough and is the safer flag: it cannot wipe an NVMe
that still has an install on it.

## Reinstall K3s on a worker

```bash
ansible-playbook pb_all.yml --limit node03 --tags k3s -e k3s_force=true
```

The agent is uninstalled and reinstalled at the version `node02` runs, and
the node rejoins. Drain it first if it is `Ready`. For `ws03`, use
`just upgrade-workstation ws03`, which wraps the same run in a drain and an
uncordon ({doc}`/how-to/upgrade-k3s`).

## Re-run one stage

```bash
ansible-playbook pb_all.yml --tags tools        # CLI tools and kubeconfig in the devcontainer
ansible-playbook pb_all.yml --tags known_hosts  # SSH host keys
ansible-playbook pb_all.yml --tags servers      # dist-upgrade and node preparation
ansible-playbook pb_all.yml --tags k3s          # K3s and the etcd backup timer
ansible-playbook pb_all.yml --tags cluster      # node taints, ArgoCD and the root app
```

`servers` and `k3s` run on every node in `hosts.yml`.

`--tags cluster` is the one used most: it re-applies the ArgoCD Helm
release and the root Application, after which ArgoCD re-syncs every
service from Git. It is also how the cluster is pointed at another branch
(`just switch-branch <branch>`). {doc}`/reference/playbook-tags` lists
every tag.

## Rebuild the whole cluster

A full rebuild tears K3s down on every node and builds it again from Git,
without re-flashing anything. It is how a change to the roles, the secret
generation or the ArgoCD bootstrap is proven: such a change can break the
rebuild path while the running cluster stays healthy. The `/rebuild-cluster`
command in Claude Code runs the whole procedure, including the checks
before and after; the outline is:

1. **Prepare.** Work on a branch that is pushed. Export the credentials that
   cannot be regenerated with `just export-external-creds`, which writes a
   gitignored `.env`, and save the wildcard TLS certificate so Let's Encrypt
   is not asked for a new one. If Minecraft is enabled, check that every
   world is on `nfs-stable` (`scripts/nfs-stable-paths` reports nothing to
   move).
2. **Decommission.**

   ```bash
   ansible-playbook pb_decommission.yml
   ```

   The playbook, in order: stops the etcd backup timer; deletes the ArgoCD
   Applications with an orphan cascade, so ArgoCD stops re-creating things;
   scales down monitoring and scrap (scrap gracefully, so Litestream makes
   its last sync) and deletes the Prometheus and Grafana PVCs; uninstalls
   ArgoCD and deletes the platform namespaces; uninstalls K3s, workers
   first and `node02` last; and removes `/var/lib/rancher`,
   `/var/lib/kubelet` and the leftover K3s files. It checks on every node
   that nothing is still mounted under those two directories before
   deleting them, so a stuck mount cannot lead the delete into a PV or an
   NFS volume. It is safe to re-run if interrupted.
3. **Rebuild.** One run installs K3s, ArgoCD and the sealed-secrets
   controller, generates and seals every secret with the new cluster's key,
   commits and pushes them, and creates the root app:

   ```bash
   set -a && source .env && set +a
   GENERATE_SECRETS=true ansible-playbook pb_all.yml \
     --tags k3s,servers,cluster -e repo_branch=<branch>
   ```

4. **Verify and merge.** Sync, restore the certificate, restart Dex, check
   every app, SealedSecret and login, then merge the branch (it carries the
   re-sealed secrets) and point ArgoCD back at `main` with
   `ansible-playbook pb_all.yml --tags cluster`.

{doc}`/tutorials/build-the-cluster` walks through the same build from bare
metal, with the one-time steps a rebuild does not repeat.

### What a rebuild keeps

`pb_decommission.yml` never touches the NAS, and by default it leaves the
local PV directories alone. The rebuilt cluster re-creates the same static
PVs, so each claim binds to the directory or NAS folder it had before.

| Data | Where it lives | After a rebuild |
|------|----------------|-----------------|
| Prometheus, Grafana | `/var/lib/k8s-data/*` on `node04` | Kept; the new PVCs bind to the same `local-nvme` PVs |
| Jellyfin config, scrap's backup copy and frozen copy | `/home/k8s-data/*` on `nuc2` | Kept |
| scrap's live data and backups | The NAS, static NFS PVs under `/bigdisk/k8s-cluster` | Kept; scrap restores its database from the Litestream replica |
| Minecraft worlds and other `nfs-stable` claims | The NAS, `/k8s-dynamic/stable/<namespace>/<claim>` | Kept; a claim of the same name finds its folder ({doc}`/how-to/nfs-stable-paths`) |
| `nfs-rwx` claims | The NAS, a folder whose name includes the PV's | Left on the NAS, but the new claim starts empty in a new folder |
| Backups | The NAS, `/bigdisk/k8s-cluster/backups` | Kept |
| etcd, Secrets, the sealing key | `node02` | Gone: the cluster is new, and every secret is re-sealed |

To start with empty local volumes as well, opt in to the destructive flag.
Prometheus and Grafana then come up empty, and Jellyfin's library database
and scrap's off-NAS backup copy are deleted:

```bash
ansible-playbook pb_decommission.yml -e wipe_local_data=true
```

Use it only when the owner has asked for a clean slate. It is the only
thing, apart from a re-flash, that removes those directories.

## What each operation does to data

| Operation | RK1 eMMC | RK1 NVMe | `local-nvme` directories | The NAS | Cluster state (etcd) |
|-----------|----------|----------|--------------------------|---------|----------------------|
| `--tags cluster` | Unchanged | Unchanged | Kept | Untouched | Kept; ArgoCD re-syncs |
| `k3s_force` on a worker | Unchanged | Unchanged | Kept | Untouched | Kept |
| `pb_decommission.yml`, then rebuild | Unchanged | Unchanged | Kept | Untouched | New cluster from Git |
| `pb_decommission.yml -e wipe_local_data=true` | Unchanged | Unchanged | **Deleted on every node** | Untouched | New cluster from Git |
| `do_flash` of an RK1 whose NVMe has a partition table | Staging OS written | Unchanged | Kept | Untouched | Unchanged; the play stops |
| `flash_force` of an RK1 | U-Boot only, no partition table | Erased, fresh Ubuntu | **Lost on that node** | Untouched | Lost if the node is `node02` |

## Troubleshooting a flash

If `tpi flash` fails with `Error occured during flashing: "USB"`,
power-cycle the BMC itself, not just the node, and re-run the playbook. The
BMC's USB subsystem sometimes gets into a state that only a full power
cycle clears.

If an RK1 does not come back after its flash, watch its console from the
BMC with `tpi uart -n <slot> get`. If the U-Boot NVMe wipe failed ("NVMe
zap FAILED"), the script powers the node off: re-run the flash.

If the play stops with "The NVMe of `<node>` has a partition table",
`do_flash` flashed a node that didn't answer SSH but whose NVMe may hold a
working install, and left that NVMe alone. The eMMC now holds the staging
OS and the node is powered off. Either:

- re-run with `-e flash_force=true` to reinstall the node, which wipes its
  NVMe (the rules above apply); or
- keep the NVMe install: clear the eMMC's partition table (`wipefs --all`
  on the eMMC, for example from the BMC with the slot in `tpi advanced msd`
  mode). U-Boot then finds no partition table on the eMMC and boots the
  NVMe install again. That clears only the partition table signatures
  (LBA 0–1 and the backup GPT at the far end), the same write the install
  itself makes, and leaves U-Boot, from LBA 64, alone.

{doc}`/reference/troubleshooting` covers problems after the node is up.
