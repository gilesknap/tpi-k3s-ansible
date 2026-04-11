# Re-flash and Rebuild

This guide covers common recovery and rebuild operations: re-flashing nodes,
reinstalling K3s, and forcing service redeployment.

## Force flags

The playbook is fully idempotent — it skips steps that are already completed. Use
force flags to override this behaviour:

| Flag | Effect |
|------|--------|
| `-e flash_force=true` | Re-flash all nodes (erases eMMC even if OS is installed) |
| `-e do_flash=true` | Enable flashing. But does not flash nodes with OS installed |
| `-e k3s_force=true` | Uninstall and reinstall K3s on all nodes |
| `-e cluster_force=true` | Force reinstall of ArgoCD and cluster services |

## Re-flash and rebuild the entire cluster

```bash
ansible-playbook pb_all.yml -e flash_force=true
```

This flashes every node with a fresh Ubuntu image, reinstalls K3s, and redeploys all
services. This is the nuclear option — use it when you want a completely clean slate.

## Re-flash a single node

Use `--limit` to target specific hosts. Always include the Turing Pi BMC host as well
(it is needed for the flash operation):

```bash
ansible-playbook pb_all.yml --limit turingpi,node03 -e flash_force=true
```

## Reinstall K3s on all nodes

```bash
ansible-playbook pb_all.yml --tags k3s,cluster -e k3s_force=true
```

This uninstalls K3s from every node, reinstalls it, and redeploys ArgoCD and all services.
Stateful workload data under `/home/k8s-data/*` (nuc2) and `/var/lib/k8s-data/*`
(RK1 nodes) is preserved by default — these host directories back the static
`local-nvme` PVs and are left untouched unless `-e wipe_local_data=true` is
passed. NFS backups on the NAS are always preserved (they live outside the
cluster).

## Reinstall K3s on a single worker

```bash
ansible-playbook pb_all.yml --limit node03 --tags k3s -e k3s_force=true
```

The worker will be removed from the cluster, K3s will be reinstalled, and it will rejoin
as a worker.

## Redeploy cluster services only

```bash
ansible-playbook pb_all.yml --tags cluster -e cluster_force=true
```

This reinstalls ArgoCD. After ArgoCD is up, it resynchronises all services from Git.

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
| Re-flash | Erased | Preserved | Preserved (on host) | Preserved (external) | Redeployed from Git |
| K3s reinstall | Unchanged | Unchanged | Preserved | Preserved | Redeployed from Git |
| Cluster redeploy | Unchanged | Unchanged | Preserved | Preserved | Reinstalled |

The `local-nvme` data directories are `/home/k8s-data/*` on nuc2 and
`/var/lib/k8s-data/*` on RK1 nodes. They are only removed when the
decommission playbook is run with `-e wipe_local_data=true`.

:::{note}
eMMC always remains the bootloader for RK1 nodes. The `ubuntu-rockchip-install` tool
(used by `move_fs`) copies the OS to NVMe but does not change the boot device. Re-flashing
eMMC always restores the node to a bootable state.
:::

## Troubleshooting flash failures

If `tpi flash` fails with `Error occured during flashing: "USB"`:

1. **Power-cycle the BMC** (not just the nodes). This is a BMC firmware USB enumeration bug.
2. Re-run the playbook.

The BMC USB subsystem sometimes gets into a bad state that only a full power cycle resolves.
