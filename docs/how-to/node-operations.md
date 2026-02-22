# Node Operations

Common operations for managing cluster nodes: shutdown, reboot, drain, add, and remove.

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
