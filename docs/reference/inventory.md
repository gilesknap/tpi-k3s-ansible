# Inventory reference

`hosts.yml` at the repo root is the only Ansible inventory (`ansible.cfg` names
it, so no `-i` is needed). It lists machines by name, without addresses: the
router's DNS resolves `node02`, `nuc2` and the rest, and the `known_hosts` role
looks each one up as `<name>.lan` (`local_domain`).

For what the machines are, see {doc}`/explanations/architecture/hardware`.

## Groups

| Group | Members | Used by |
|-------|---------|---------|
| `controller` | `localhost`, with a local connection | Sets how Ansible reaches the devcontainer. The plays that run there (`tools`, `cluster`) target `localhost` directly |
| `turing_pis` | `turingpi` (the BMC) | The `flash` play, which drives `tpi` on the BMC, and `known_hosts` |
| `turingpi_nodes` | `node02` to `node04` | The `flash` role, to find the BMC's nodes; member of `all_nodes` |
| `extra_nodes` | `ws03`, `nuc2`, `nuc1` | `pb_add_nodes.yml`, which gives Ansible its account on a machine whose OS was installed by hand; member of `all_nodes` |
| `all_nodes` | `turingpi_nodes` and `extra_nodes` | Every node play in `pb_all.yml` (`known_hosts`, `servers`, `k3s`, `claude_key`) and `pb_decommission.yml` |
| `nas` | `gknas` (the NAS) | `pb_nas.yml` only ({doc}`/how-to/nas-ubuntu-zfs`). The NAS is not a cluster node: it is in no other group, so no play of `pb_all.yml`, `pb_add_nodes.yml` or `pb_decommission.yml` reaches it, and the `nas` role refuses a host that is in `all_nodes` |

`turing_pis` connects as `tpi_user` (`root`); the node groups connect as
`ansible_account` (`ansible`), with sudo.

### The `<bmc>_nodes` rule

The group holding a Turing Pi's nodes must be named after the BMC's inventory
name plus `_nodes`. The `flash` role runs on the BMC and finds its nodes with
`groups[inventory_hostname + '_nodes']`, so the BMC `turingpi` owns
`turingpi_nodes`. A second board called `turingpi2` would need a
`turingpi2_nodes` group, added to `all_nodes` as well (`hosts.yml` carries a
commented-out sketch of one).

## Per-node variables

| Variable | Applies to | Values | Effect |
|----------|------------|--------|--------|
| `slot_num` | Turing Pi nodes, required | `1` to `4` | The slot on the board, which `tpi` powers and flashes (slot 1 is nearest the coin battery) |
| `type` | Turing Pi nodes, required | `rk1`, `pi4` | The compute module, which decides the image flashed |
| `root_dev` | RK1, optional | Device path | The disk the OS is installed on (`/dev/nvme0n1`); the eMMC then holds only U-Boot. `move_fs` refuses it on any other `type` |
| `nvidia_gpu_node` | Optional | `true`/`false` | Installs the NVIDIA driver and container toolkit, configures K3s's containerd with the NVIDIA runtime and labels the node `nvidia.com/gpu.present=true` |
| `intel_gpu_node` | Optional | `true`/`false` | Labels the node `intel.feature.node.kubernetes.io/gpu=true`, so the Intel GPU device plugin runs there and advertises `gpu.intel.com/i915`. Installs nothing on the node |
| `workstation` | Optional | `true`/`false` | Registers the agent with the `workstation=true:NoSchedule` taint and the `node-role=workstation` label, so nothing lands there first. Only tolerating pods (GPU, monitoring) schedule on it. The label keeps it out of the automatic K3s upgrades, and kured does not tolerate the taint, so it is never rebooted by automation ({doc}`/explanations/upgrade-model`) |
| `node_ip` | Optional | IPv4 address | Passed to the agent as `--node-ip`. Needed on a multi-homed node whose default route is on the wrong subnet |
| `install_profile` | x86 hosts, optional | `server`, `desktop` | Gives the host an entry on the install stick ({doc}`/how-to/install-stick`); `desktop` adds `ubuntu-desktop-minimal` and NetworkManager |
| `install_disk_serial` | With `install_profile` | Disk serial | The OS disk the install erases. The install refuses unless exactly one disk has this serial |
| `install_disk_model` | With `install_profile`, optional | Disk model | Also checked against the OS disk's model, as `lsblk` shows it |
| `install_machine_macs` | With `install_profile`, required | List of MACs, lower case | The host's network ports. The install refuses unless one is present, so the entry runs on this machine only |
| `install_ansible_uid` | With `install_profile`, optional | Number | The `ansible` account's uid on the new install, so it still owns its home on a disk the install keeps (`nuc2`: 1001) |
| `extra_mounts` | Optional | List of `path`, `src`, `fstype`, `opts` | fstab entries for the node's other disks. The `k8s_data_dirs` role (`--tags servers`) writes them and mounts each one not marked `noauto`. It never formats a disk. `nuc2` lists `/home` and `/mnt/backup` |

The two GPU flags default to `false` in `group_vars/all.yml`. Which node is the
control plane is not an inventory setting: `control_plane` and
`standby_control_plane` in `group_vars/all.yml` name them
({doc}`/reference/variables`).

## The inventory as it stands

| Host | Group | Address | Slot | `type` | `root_dev` | Flags | In the cluster |
|------|-------|---------|------|--------|------------|-------|----------------|
| `turingpi` | `turing_pis` | 192.168.1.80 | | | | | BMC, not a node |
| `node02` | `turingpi_nodes` | 192.168.1.82 | 2 | `rk1` | `/dev/nvme0n1` | | Control plane and etcd (`control_plane`) |
| `node03` | `turingpi_nodes` | 192.168.1.83 | 3 | `rk1` | `/dev/nvme0n1` | | Worker, warm standby (`standby_control_plane`) |
| `node04` | `turingpi_nodes` | 192.168.1.84 | 4 | `rk1` | `/dev/nvme0n1` | | Worker |
| `ws03` | `extra_nodes` | 192.168.1.10 | | | | `nvidia_gpu_node`, `workstation` | Worker, tainted |
| `nuc2` | `extra_nodes` | 192.168.1.92 | | | | `node_ip: 192.168.1.92`, `intel_gpu_node` | Worker |
| `nuc1` | `extra_nodes` | 192.168.1.91 | | | | | Worker |
| `gknas` | `nas` | 192.168.1.3 | | | | | No: the NAS, configured by `pb_nas.yml` |

The addresses are not in `hosts.yml`; they are the ones the router hands out,
and the sandbox allow-list (`.devcontainer/claude-sandbox.conf`) repeats them.

Slot 1 of the board is not in the inventory. It holds `node01`, a CM4 that
was the control plane before `node02` and is no longer part of the cluster.

## What else to touch when a node is added or removed

`hosts.yml` is not the only file that knows the list of nodes. The `/add-node`
command covers the inventory, the playbooks and the RCON allow-list; the other
rows are done by hand, and {doc}`/how-to/node-operations` has the procedures.

| Where | What | Why |
|-------|------|-----|
| `.devcontainer/claude-sandbox.conf` | An `allow-ip` line for the node's address, then `just sandbox-conf` | claude-sandbox blocks every private address that is not listed, so Ansible, SSH and kubectl inside it cannot reach an unlisted node |
| `kubernetes-services/values.yaml`, `minecraft.worlds.rcon_allowed_cidrs` | The node's address as a `/32` under `except` | Keeps the node's host off world RCON when it arrives from its LAN address (through Cilium's tunnel no CIDR matches it anyway), so every node but the world node (`nuc2`) and `ws03` is carved out of the LAN allow-list; ws03 is admitted by name instead (`rcon_allowed_nodes`) |
| `group_vars/all.yml`, `k8s_data_dirs` and `values.yaml`, `local_storage` | An entry in each, with the same `node` and `path` | Only if the node will hold a `local-nvme` PV: the first creates the host directory, the second the PV pinned to it ({ref}`move-a-local-nvme-pv`) |
| `group_vars/all.yml`, `control_plane` and `standby_control_plane` | The node's name | Only if it takes one of those roles ({doc}`/how-to/recover-control-plane`) |
| `pb_all.yml --tags claude_key` (or `just claude-ssh-bootstrap`) | Run once the node is up | Puts the Claude sandbox's SSH key on the node's `ansible` account. A flashed RK1 gets it from its cloud-init seed instead |
| The router | A fixed address and a DNS name for the node | The inventory holds names only |

A machine outside the Turing Pi also needs its OS installed by hand and one run
of `pb_add_nodes.yml` before `pb_all.yml` can reach it
({doc}`/reference/playbook-tags`).
