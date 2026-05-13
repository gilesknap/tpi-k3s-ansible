# Node Operations

Common operations for managing cluster nodes: shutdown, reboot, drain, add, and remove.

## Apply package updates to nodes

The `update_packages` role is part of the `servers` play — **not** a tag of its own.
To run package updates (e.g. after adding a new package to the role):

```bash
# All nodes
ansible-playbook pb_all.yml --tags servers

# Specific nodes only
ansible-playbook pb_all.yml --tags servers --limit node02,node03
```

:::{note}
`--tags update_packages` will silently do nothing — the correct tag is `servers`,
which runs both the `move_fs` and `update_packages` roles.
:::

## Shutdown all nodes

```bash
ansible all_nodes -a "/sbin/shutdown now" -f 10 --become
```

## Reboot all nodes

```bash
ansible all_nodes -m reboot -f 10 --become
```

## Shutdown or reboot a single node

```bash
# Shutdown
ansible node03 -a "/sbin/shutdown now" --become

# Reboot
ansible node03 -m reboot --become
```

## Hard power-cycle a Turing Pi node via the BMC

Use this when a Turing Pi node is `NotReady` and SSH times out — the
graceful `ansible -m reboot` above needs a working kubelet and `sshd`
on the target, so it cannot recover an unreachable node.

The BMC is reachable as `root@turingpi`. Each slot maps to a node via
`slot_num` in `hosts.yml`: node01→1, node02→2, node03→3, node04→4.
`nuc2` and `ws03` are not on the BMC — power them with their own
buttons.

```bash
# Inspect what the BMC thinks of all four slots
ssh root@turingpi 'tpi power status'

# Power-cycle a single node (off → wait → on)
ssh root@turingpi 'tpi power off -n 4 && sleep 15 && tpi power on -n 4'

# Wait for it to rejoin the cluster
kubectl get nodes -w
```

:::{warning}
A hard power-cycle is an unclean shutdown for any in-flight writes. If
the node carries live local-PV data (Prometheus on node02, Grafana on
node03, Open-WebUI on node04 — see the "Local PV data paths are sacred"
rule in `CLAUDE.md`), expect fsck on boot and check the affected pods'
logs once the node returns.
:::

:::{note}
Don't `kubectl drain` first — the node is already unreachable, so the
drain will hang waiting for pods that can't be contacted. Just
power-cycle and let workloads reschedule (or come back, for DaemonSets
pinned to the node, like `rkllama` on node04).
:::

## Drain a node for maintenance

Before taking a node offline for hardware maintenance:

```bash
# Drain the node (evict pods, mark unschedulable)
kubectl drain node03 --ignore-daemonsets --delete-emptydir-data

# Perform maintenance...

# Uncordon the node (allow pods to schedule again)
kubectl uncordon node03
```

## Add extra (non-Turing Pi) nodes

To add standalone Linux servers to the cluster:

### Step 1: Add to inventory

Edit `hosts.yml` and add entries under `extra_nodes`:

```yaml
extra_nodes:
  hosts:
    nuc1:
    nuc2:
  vars:
    ansible_user: "{{ ansible_account }}"

all_nodes:
  children:
    turingpi_nodes:
    extra_nodes:       # Make sure extra_nodes is listed here
```

### Step 2: Bootstrap Ansible access

```bash
ansible-playbook pb_add_nodes.yml
```

This prompts for an existing username and password on the new servers, creates the
`ansible` user with SSH key authentication and passwordless sudo.

### Step 3: Join the cluster

```bash
ansible-playbook pb_all.yml --limit nuc1,nuc2 --tags known_hosts,servers,k3s
```

The new nodes will be prepared (known_hosts, package updates) and joined to the
existing K3s cluster as workers.

## Remove a worker node

### Step 1: Drain the node

```bash
kubectl drain node03 --ignore-daemonsets --delete-emptydir-data
```

### Step 2: Delete from Kubernetes

```bash
kubectl delete node node03
```

### Step 3: Uninstall K3s on the node

```bash
ssh ansible@node03 'sudo /usr/local/bin/k3s-agent-uninstall.sh'
```

### Step 4: Remove from inventory

Remove the node from `hosts.yml` and commit the change.

## Run an ad-hoc command on all nodes

```bash
# Check disk usage
ansible all_nodes -a "df -h" --become

# Check K3s agent status
ansible all_nodes -a "systemctl status k3s-agent" --become

# Run a role standalone
ansible all_nodes -m include_role -a name=known_hosts
```
