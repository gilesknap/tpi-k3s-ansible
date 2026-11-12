# Re-flash and Rebuild

This guide covers common recovery and rebuild operations: re-flashing nodes,
reinstalling K3s, and forcing service redeployment.

## Force flags

The playbook is fully idempotent — it skips steps that are already completed. Use
force flags to override this behaviour:

| Flag | Effect |
|------|--------|
| `-e flash_force=true` | Re-flash all nodes (erases eMMC even if OS is installed, and on RK1s with `root_dev` the NVMe) |
| `-e do_flash=true` | Enable flashing, but only of nodes that don't answer SSH. On an RK1 with `root_dev` it never wipes an NVMe that has a partition table: the play stops and asks for `flash_force` |
| `-e k3s_force=true` | Uninstall and reinstall K3s on all nodes |

## Re-flash and rebuild the entire cluster

```bash
ansible-playbook pb_all.yml -e flash_force=true
```

This flashes every node with a fresh Ubuntu image, reinstalls K3s, and redeploys all
services. This is the nuclear option — use it when you want a completely clean slate.
Data on the NAS is untouched. Claims on the `nfs-stable` class (the
default, including Minecraft worlds) come back with their data (see
{doc}`nfs-stable-paths`).

## Re-flash a single node

Use `--limit` to target specific hosts. Always include the Turing Pi BMC host as well
(it is needed for the flash operation):

```bash
ansible-playbook pb_all.yml --limit turingpi,node03 -e flash_force=true
```

:::{warning}
**A re-flash is a fresh node.** On an RK1 with `root_dev`, the flash wipes the NVMe
and installs Ubuntu on it again, so everything on it is lost, including the
`local-nvme` PV data under `/var/lib/k8s-data` (for example Prometheus and
Grafana on node04 in the default inventory). Back up or move that data before
re-flashing the node.
:::

An RK1 re-flash takes about 25 minutes. The node gets new SSH host keys, which the
`known_hosts` play records. If the node's old OS still answers SSH, the flash clears
the NVMe through it first; otherwise the BMC clears it from the U-Boot prompt over
the node's UART. See [](../explanations/ansible-roles.md) for the full sequence.

## Reinstall K3s on all nodes

```bash
ansible-playbook pb_all.yml --tags k3s,cluster -e k3s_force=true
```

This uninstalls K3s from every node, reinstalls it, and redeploys ArgoCD and all services.
Stateful workload data under `/home/k8s-data/*` (nuc2) and `/var/lib/k8s-data/*`
(RK1 nodes) is preserved by default — these host directories back the static
`local-nvme` PVs and are left untouched (only `pb_decommission.yml -e
wipe_local_data=true` or a re-flash removes them). NFS backups on the NAS are always preserved (they live outside the
cluster), and so is scrap's data, which is on static NFS volumes there.

## Reinstall K3s on a single worker

```bash
ansible-playbook pb_all.yml --limit node03 --tags k3s -e k3s_force=true
```

The worker will be removed from the cluster, K3s will be reinstalled, and it will rejoin
as a worker.

## Redeploy cluster services only

```bash
ansible-playbook pb_all.yml --tags cluster
```

This re-runs the ArgoCD helm install/upgrade. After ArgoCD is up, it resynchronises all services from Git.

## Run a single stage

Use tags to run individual stages:

```bash
ansible-playbook pb_all.yml --tags tools       # Install CLI tools in devcontainer
ansible-playbook pb_all.yml --tags known_hosts  # Update SSH known_hosts
ansible-playbook pb_all.yml --tags servers      # OS migration + package updates
ansible-playbook pb_all.yml --tags k3s          # Install/update K3s
ansible-playbook pb_all.yml --tags cluster      # Install/update ArgoCD + services
```

## What happens to data during a rebuild?

| Operation | eMMC | NVMe | `local-nvme` data dirs | NFS backups on NAS | ArgoCD state |
|-----------|------|------|-------------------------|--------------------|--------------|
| Re-flash (CM4, or RK1 without `root_dev`) | Erased | Unchanged | **Lost** (on the erased root fs) | Preserved (external) | Redeployed from Git |
| Re-flash (RK1 with `root_dev`) | Erased (U-Boot only) | Erased, fresh install | **Lost** on that node | Preserved (external) | Redeployed from Git |
| K3s reinstall | Unchanged | Unchanged | Preserved | Preserved | Redeployed from Git |
| Cluster redeploy | Unchanged | Unchanged | Preserved | Preserved | Reinstalled |

The `local-nvme` data directories are `/home/k8s-data/*` on nuc2 and
`/var/lib/k8s-data/*` on RK1 nodes. The decommission playbook removes them only
with `-e wipe_local_data=true`, and a re-flash of an RK1 with `root_dev` loses
them along with the rest of its NVMe.

## Troubleshooting flash failures

If `tpi flash` fails with `Error occured during flashing: "USB"`:

1. **Power-cycle the BMC** (not just the nodes). This is a BMC firmware USB enumeration bug.
2. Re-run the playbook.

The BMC USB subsystem sometimes gets into a bad state that only a full power cycle resolves.

If an RK1 does not come back after its flash, watch its console from the BMC with
`tpi uart -n <slot> get`. If the U-Boot NVMe wipe failed ("NVMe zap FAILED"), the
script powers the node off: re-run the flash.

If the play stops with "The NVMe of `<node>` has a partition table", `do_flash`
flashed a node that didn't answer SSH but whose NVMe may hold a working install, and
left that NVMe alone. The eMMC now holds the staging OS and the node is powered off.
Re-run with `-e flash_force=true` to reinstall the node, which wipes its NVMe. To
keep the NVMe install instead, clear the eMMC's partition table (`wipefs --all` on
the eMMC, for example from the BMC with the slot in `tpi advanced msd` mode): U-Boot
then finds no partition table on the eMMC and boots the NVMe install again.
