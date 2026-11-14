# Playbook tags reference

`pb_all.yml` is the one playbook that builds and updates the cluster. Each of
its plays carries a tag, so a single stage, or a few, can be run on their own.
Run it in the devcontainer, from the repo root.

## Tag reference

| Tag | Play | Roles | Runs on | Description |
|-----|------|-------|---------|-------------|
| `tools` | Install client tools | `tools` | localhost | Installs helm, kubectl, kubeseal, argocd and the port-forward scripts, and fetches the kubeconfig ({doc}`/reference/cli-tools`) |
| `flash` | Bare metal provisioning | `flash` | `turing_pis` | Only with `do_flash`. Flashes Turing Pi nodes through the BMC; on an RK1, mainline U-Boot plus an eMMC staging copy of Ubuntu 26.04 |
| `known_hosts` | Update known_hosts | `known_hosts` | `all_nodes`, `turing_pis` | Updates the SSH known_hosts files; fails a host whose key scan returns nothing |
| `servers` | Prepare nodes (four plays) | `move_fs`, `rk1_os`, `update_packages`, `k8s_data_dirs`, `node_reboot` | `all_nodes` | Installs Ubuntu on an RK1's NVMe, converts older RK1 installs, dist-upgrades, installs dependencies and creates the local PV directories. Reboots a cluster node only with `-e reboot_now=true` |
| `rk1_os` | Convert RK1 nodes | `rk1_os` | RK1 nodes, `serial: 1` | Converts an RK1 still on the old ubuntu-rockchip vendor layout to stock Ubuntu 26.04; skips a standard install, which is what `node02` to `node04` now are |
| `sysctl` | Update all nodes | `update_packages` (one task) | `all_nodes` | Only the `net.mptcp.enabled=0` sysctl, which reaches the tainted nodes that the `kernel-settings` DaemonSet cannot |
| `k8s_data_dirs` | Update all nodes | `k8s_data_dirs` | `all_nodes` | Only the local PV host directories from `k8s_data_dirs`; never deletes data |
| `k3s` | Install K3s | `k3s`, `etcd_backup` | `all_nodes` | Installs or updates the K3s control plane and workers, and the control plane's nightly etcd backup timer |
| `apparmor` | Install K3s | `k3s` (`apparmor.yml` only) | `all_nodes` | Only the corrected containerd AppArmor profile (see {doc}`/reference/troubleshooting`) |
| `etcd_backup` | Install K3s | `etcd_backup` | `node02` (the control plane) | Only the nightly encrypted etcd backup timer ({doc}`/how-to/backup-restore`) |
| `cluster` | Deploy services | `cluster` | localhost | Installs ArgoCD and its root Application, and sets the control plane and standby taints |
| `claude_key` | Manage Claude sandbox's pub key | (task) | `all_nodes` | Adds (or with `-e claude_pubkey_state=absent` removes) the Claude sandbox key on the `ansible` account; used by `just claude-ssh-bootstrap` |

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
| `--tags tools` | Refresh the CLIs and kubeconfig in the devcontainer (also run when the devcontainer is created) |
| `--tags known_hosts,servers,k3s --limit nuc1` | Bring one node up to date, or join a new one |
| `--tags servers` | Apply package updates to every node; kured reboots them in its nightly window |
| `--tags k3s,cluster -e k3s_force=true` | Reinstall K3s and redeploy every service |
| `--tags cluster` | Reinstall ArgoCD's config, taints and root Application only (what `just switch-branch` runs) |
| `-e do_flash=true` | The whole playbook, flash included (no tag needed) |

## Using `--limit`

Restrict which hosts are targeted:

```bash
# Single node
ansible-playbook pb_all.yml --limit node03 --tags k3s -e k3s_force=true

# Turing Pi BMC + specific node (needed for flash)
ansible-playbook pb_all.yml --limit turingpi,node03 -e flash_force=true

# Only the nodes outside the Turing Pi (ws03, nuc1, nuc2)
ansible-playbook pb_all.yml --limit extra_nodes --tags known_hosts,servers,k3s

# The local PV directories on nuc2
ansible-playbook pb_all.yml --limit nuc2 --tags k8s_data_dirs
```

:::{note}
When using `--limit` with the `flash` tag, always include the BMC (`turingpi`),
because the flash role runs on the BMC, not on the node itself.
An RK1 flash is only complete after the `servers` tag's `move_fs` has installed its
NVMe, so for an RK1 run the whole playbook (or at least
`--tags flash,known_hosts,servers`), not `--tags flash` alone.
:::

## Standalone playbooks

| Playbook | Purpose | Flags |
|----------|---------|-------|
| `pb_all.yml` | Builds and updates the cluster: every stage above | Tags, `--limit`, and the `-e` overrides in {doc}`/reference/variables` |
| `pb_add_nodes.yml` | Gives Ansible control of a machine in `extra_nodes` whose OS was installed by hand: creates the `ansible` account, authorises `pub_keys/ansible_rsa.pub` and adds passwordless sudo. Safe to re-run | `--limit <node> -e ansible_user=<existing user> -K`. It must be `-e`, not `-u`: the inventory sets `ansible_user` to an account that does not exist on the machine yet |
| `pb_decommission.yml` | Tears the whole cluster down, in order: stops the etcd backup timer, stops ArgoCD reconciling, scales down workloads and deletes chart-owned PVCs, removes ArgoCD and the namespaces, removes the systemd units this repo adds beside K3s, uninstalls K3s (workers, then the control plane) and cleans up node state. Idempotent | None by default: `/home/k8s-data` (`nuc2`) and `/var/lib/k8s-data` (RK1s) are kept, as is everything on the NAS. `-e wipe_local_data=true` also deletes those two directories, and with them every `local-nvme` PV's data |

`pb_decommission.yml` is the first half of a rebuild
({doc}`/how-to/reflash-rebuild`, or the `/rebuild-cluster` command). It is not
the way to remove one node: {doc}`/how-to/node-operations` covers that.

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
