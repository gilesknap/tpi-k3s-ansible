# Playbook Tags Reference

The main playbook `pb_all.yml` uses tags to allow running individual stages or
combinations. Tags map to plays within the playbook.

## Tag reference

| Tag | Play | Roles | Runs on | Description |
|-----|------|-------|---------|-------------|
| `tools` | Install client tools | `tools` | localhost | Installs helm, kubectl, kubeseal, scripts |
| `flash` | Bare metal provisioning | `flash` | turing_pis | Flashes Ubuntu to compute modules (BMC) |
| `known_hosts` | Update known_hosts | `known_hosts` | all_nodes, turing_pis | Updates SSH known_hosts (serial: 1) |
| `servers` | Prepare nodes | `move_fs`, `update_packages` | all_nodes | OS migration, dist-upgrade, dependencies |
| `k3s` | Install K3s | `k3s` | all_nodes | Installs K3s control plane + workers |
| `cluster` | Deploy services | `cluster` | localhost | Installs ArgoCD, bootstraps services |

## Running individual stages

```bash
# Single stage
ansible-playbook pb_all.yml --tags tools
ansible-playbook pb_all.yml --tags k3s

# Multiple stages
ansible-playbook pb_all.yml --tags k3s,cluster

# Skip a stage
ansible-playbook pb_all.yml --skip-tags flash
```

## Common tag combinations

| Command | Use case |
|---------|----------|
| `--tags tools` | Update CLI tools in devcontainer |
| `--tags known_hosts,servers,k3s,cluster` | Full setup without flashing (pre-existing servers) |
| `--tags k3s,cluster -e k3s_force=true` | Rebuild K3s and all services |
| `--tags cluster` | Redeploy ArgoCD and services only |
| `--tags cluster -e cluster_force=true` | Force reinstall ArgoCD |
| `-e do_flash=true` | Full run including flash (no tag needed — runs all) |

## Using `--limit`

Restrict which hosts are targeted:

```bash
# Single node
ansible-playbook pb_all.yml --limit node03 --tags k3s -e k3s_force=true

# Turing Pi BMC + specific node (needed for flash)
ansible-playbook pb_all.yml --limit turingpi,node03 -e flash_force=true

# Only extra nodes
ansible-playbook pb_all.yml --limit extra_nodes --tags known_hosts,servers,k3s
```

:::{note}
When using `--limit` with the `flash` tag, always include the Turing Pi BMC host
(e.g. `turingpi`) because the flash role runs on the BMC, not on the node itself.
:::

## Standalone playbooks

| Playbook | Purpose |
|----------|---------|
| `pb_all.yml` | Main playbook — runs all stages |
| `pb_add_nodes.yml` | Bootstrap Ansible access on new nodes in `extra_nodes` |
| `pb_decommission.yml` | Remove a node from the cluster (preserves `/home/k8s-data` and `/var/lib/k8s-data` by default; pass `-e wipe_local_data=true` to also remove the on-disk PV data) |

## Ad-hoc commands

Run Ansible modules directly without a playbook:

```bash
# Ping all nodes
ansible all_nodes -m ping

# Run a shell command
ansible all_nodes -a "uptime" --become

# Run a single role
ansible all_nodes -m include_role -a name=known_hosts
```
