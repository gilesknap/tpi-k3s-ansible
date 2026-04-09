---
name: add-node
description: Interactively add a new worker node to an existing K3s cluster — configure inventory, bootstrap SSH, join cluster, and adjust topology settings.
user_invocable: true
---

# Add Node

Guide the user through adding a new worker node to an existing cluster. Ask
questions, update the inventory, run the appropriate playbooks, and adjust
cluster-wide settings that depend on node count (Longhorn replicas, control
plane taint, cloudflared replicas).

## Important rules

- **Never commit or push** without asking the user first.
- **Never `kubectl apply/patch/edit`** — ArgoCD self-heals. Read-only kubectl
  is fine. Exception: `kubeseal` for secret generation.
- Use `uv run` for any git commits (pre-commit hooks need the uv venv).

## Phase 1: Gather information

Ask the user:

1. **Is this a Turing Pi node or a standalone server?**
   - Turing Pi: Which BMC? What slot number? What type (RK1/CM4)? NVMe drive?
   - Standalone: Hostname or IP? What OS? (any modern Linux distribution)
   - Architecture? (x86/amd64 or ARM64)

2. **Does this node have special hardware?**
   - NVIDIA GPU? (`nvidia_gpu_node: true`)
   - Is it a workstation that may reboot? (`workstation: true` for taint)

3. **What is the node's intended role?**
   - General worker (default)
   - GPU compute (for llama.cpp)
   - Additional storage node
   - Dedicated x86 node (for Supabase migration)

## Phase 2: Update inventory

Read `hosts.yml` before editing. Add the new node to the appropriate group:

### Turing Pi node
Add under the matching `<bmc_hostname>_nodes` group with `slot_num` and `type`.
If this is a new Turing Pi board, also add the BMC to `turing_pis`.

### Standalone server
Add under `extra_nodes`. Create the group if it doesn't exist.

```yaml
extra_nodes:
  hosts:
    <hostname>:
      nvidia_gpu_node: true   # only if GPU
      workstation: true        # only if workstation
      node_ip: 192.168.1.x    # only if multi-homed (see below)
      flannel_iface: enp3s0   # only if multi-homed (see below)
  vars:
    ansible_user: "{{ ansible_account }}"
```

Ensure `extra_nodes` is listed under `all_nodes.children`.

### Multi-homed nodes

If the node has multiple network interfaces on different subnets, ask the user
which subnet the cluster uses. K3s and flannel auto-detect the IP from the
default route interface, which may be the wrong subnet. Set:

- `node_ip` — the IP on the cluster subnet (passed as `--node-ip` to K3s)
- `flannel_iface` — the interface name carrying that IP (passed as
  `--flannel-iface` to K3s)

Without `flannel_iface`, flannel's VXLAN tunnel will use the wrong endpoint
and cross-node pod networking will fail.

## Phase 3: Bootstrap access

### Turing Pi node
- Ensure SSH key is on the BMC
- Flash will happen during playbook run with `-e do_flash=true`

### Standalone server
The bootstrap playbook creates the `ansible` user and copies the SSH key.
It requires `-K` for an interactive sudo password prompt, which does not work
inside Claude Code's shell. **Ask the user to run it manually** from their
terminal:

```bash
ansible-playbook pb_add_nodes.yml --limit <hostname> -e "ansible_user=<existing-user>" -K
```

The `-e "ansible_user=<existing-user>"` override is needed because the
`extra_nodes` group sets `ansible_user` to the ansible account, which doesn't
exist yet. Ask the user for the existing SSH username on the new server.

Once the user confirms it completed, verify access:

```bash
ansible <hostname> -m ping
```

## Phase 4: Join the cluster

Confirm with the user before running.

### Turing Pi node (needs flashing)
```bash
ansible-playbook pb_all.yml --limit <hostname> -e do_flash=true
```

### Standalone server
```bash
ansible-playbook pb_all.yml --limit <hostname> --tags known_hosts,servers,k3s
```

Verify the node joined:

```bash
kubectl get nodes
```

## Phase 5: Adjust topology settings

After the node joins, check whether cluster-wide settings need updating.
Count total nodes with `kubectl get nodes` and compare to current settings.

### Longhorn replica count

Read `kubernetes-services/templates/longhorn.yaml` and check
`defaultClassReplicaCount`. Update if the new node count changes the
appropriate value:

| Total nodes | Replica count |
|-------------|---------------|
| 1           | 1             |
| 2           | 2             |
| 3+          | 3             |

Only change upward (e.g. going from 2 to 3 nodes). Existing volumes keep
their original replica count — only new volumes use the updated default.
Warn the user about this.

### Control plane taint

If going from 1 to 2+ nodes, ask the user if they want to enable the control
plane `NoSchedule` taint. If going from 1 to 3+, recommend enabling it.

The taint is managed by K3s server flags, not Ansible. To enable, re-run the
control plane play:

```bash
ansible-playbook pb_all.yml --limit <control-plane-node> --tags k3s
```

### Cloudflared replicas

If going from 1 to 2+ nodes, check if cloudflared should increase from 1 to 2
replicas (the default for multi-node clusters).

### Newly unlocked features

If the new node enables features that weren't previously available, inform the
user:

- **First x86 node added** → Open Brain (Supabase) is now possible
- **First GPU node added** → llama.cpp is now possible
- **First RK1 node added** → RKLLama is now possible
- **Third node added** → Longhorn now has full 3-replica redundancy

Point the user to the relevant how-to guide or suggest running
`/bootstrap-cluster` for the initial setup of any newly unlocked feature.

## Phase 6: Commit and deploy

If any files were changed (hosts.yml, longhorn.yaml, values.yaml), ask the
user if they want to commit. If topology changes were made to ArgoCD-managed
templates, they need to be pushed and synced:

```bash
ansible-playbook pb_all.yml --tags cluster
```

## Phase 7: Summary

Print what was done:
- Node added and joined
- Any topology changes made
- Any features now available
- Remind about `docs/how-to/node-operations` for future node management
