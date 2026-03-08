# Inventory Reference

The Ansible inventory file `hosts.yml` defines all hosts and their groupings.

## Host groups

| Group | Purpose | Used by |
|-------|---------|---------|
| `controller` | The devcontainer (localhost) | `tools`, `cluster` roles |
| `turing_pis` | Turing Pi BMC hosts | `flash`, `known_hosts` roles |
| `<bmc>_nodes` | Nodes on a specific Turing Pi | `flash`, all node roles |
| `extra_nodes` | Non-Turing Pi servers | All node roles |
| `all_nodes` | Union of all node groups | `known_hosts`, `move_fs`, `update_packages`, `k3s` |

## Naming conventions

### Turing Pi node groups

Node groups for Turing Pi boards **must** be named `<bmc_hostname>_nodes`. The flash
role uses this convention to discover which nodes belong to each BMC.

Examples:

- BMC hostname `turingpi` → node group `turingpi_nodes`
- BMC hostname `turingpi-2` → node group `turingpi-2_nodes`

### The `all_nodes` group

The `all_nodes` group is a union of all node groups. Define it using `children`:

```yaml
all_nodes:
  children:
    turingpi_nodes:
    extra_nodes:
```

## Per-node variables

| Variable | Required | Values | Description |
|----------|----------|--------|-------------|
| `slot_num` | For Turing Pi nodes | `1`–`4` | Physical slot on the board (slot 1 nearest coin battery) |
| `type` | For Turing Pi nodes | `rk1`, `pi4` | Compute module type (determines OS image) |
| `root_dev` | Optional | Device path | Target block device for OS migration (e.g. `/dev/nvme0n1`) |
| `nvidia_gpu_node` | Optional | `true`/`false` | Set `true` for nodes with an NVIDIA GPU. Installs the NVIDIA driver and container toolkit, configures k3s containerd with the NVIDIA runtime, and labels the node `nvidia.com/gpu.present=true`. Required for the llama.cpp CUDA service. |
| `workstation` | Optional | `true`/`false` | Applies `workstation=true:NoSchedule` taint and `node-role=workstation` label. Only tolerating workloads (GPU, monitoring) schedule here. |
| `node_ip` | Optional | IP address | Forces K3s to use this IP (passed as `--node-ip`). Required for multi-homed nodes where the default route interface is on the wrong subnet. |
| `flannel_iface` | Optional | Interface name | Forces flannel's VXLAN tunnel to use this interface (passed as `--flannel-iface`). Must match the interface carrying `node_ip`. Required alongside `node_ip` on multi-homed nodes. |

## Example: Turing Pi only

```yaml
controller:
  hosts:
    localhost:
      ansible_connection: local

turing_pis:
  hosts:
    turingpi:
  vars:
    ansible_user: "{{ tpi_user }}"

turingpi_nodes:
  hosts:
    node01:
      slot_num: 1
      type: pi4
    node02:
      slot_num: 2
      type: rk1
      root_dev: /dev/nvme0n1
    node03:
      slot_num: 3
      type: rk1
      root_dev: /dev/nvme0n1
    node04:
      slot_num: 4
      type: rk1
      root_dev: /dev/nvme0n1
  vars:
    ansible_user: "{{ ansible_account }}"

all_nodes:
  children:
    turingpi_nodes:
```

## Example: Standalone servers only

```yaml
controller:
  hosts:
    localhost:
      ansible_connection: local

extra_nodes:
  hosts:
    server1:
    server2:
    server3:
  vars:
    ansible_user: "{{ ansible_account }}"

all_nodes:
  children:
    extra_nodes:
```

## Example: Mixed (Turing Pi + extra nodes)

```yaml
controller:
  hosts:
    localhost:
      ansible_connection: local

turing_pis:
  hosts:
    turingpi:
  vars:
    ansible_user: "{{ tpi_user }}"

turingpi_nodes:
  hosts:
    node01:
      slot_num: 1
      type: pi4
    node02:
      slot_num: 2
      type: rk1
      root_dev: /dev/nvme0n1
  vars:
    ansible_user: "{{ ansible_account }}"

extra_nodes:
  hosts:
    nuc1:
    nuc2:
  vars:
    ansible_user: "{{ ansible_account }}"

all_nodes:
  children:
    turingpi_nodes:
    extra_nodes:
```
