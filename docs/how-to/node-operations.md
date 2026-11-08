# Node Operations

Common operations for managing cluster nodes: shutdown, reboot, drain, add, and remove.
Routine OS updates and reboots are automatic; see {doc}`/explanations/upgrade-model`.

## Apply package updates to nodes

The `update_packages` role is part of the `servers` play — **not** a tag of its own.
To run package updates (e.g. after adding a new package to the role):

```bash
# All nodes
ansible-playbook pb_all.yml --tags servers

# Specific nodes only
ansible-playbook pb_all.yml --tags servers --limit node02,node03

# Also reboot now the nodes that need it: drained, one at a time
ansible-playbook pb_all.yml --tags servers -e reboot_now=true
```

`update_packages` does not reboot a node that is in the cluster. If an upgrade
needs a reboot it leaves `/var/run/reboot-required` for kured, which drains and
reboots the node in the nightly window, and says so in the output. With
`-e reboot_now=true` the nodes that need it are drained, rebooted and uncordoned
one at a time instead. A node not yet running k3s is rebooted straight away, and
workstations are never rebooted. See {doc}`/explanations/upgrade-model`.

:::{note}
`--tags update_packages` will silently do nothing — the correct tag is `servers`,
which runs the `move_fs`, `rk1_os`, `update_packages` and `k8s_data_dirs` roles.
:::

:::{warning}
`--tags servers` also converts every RK1 node still on the old ubuntu-rockchip
vendor image (the `rk1_os` role; RK1s installed by the current `flash` role are
already stock Ubuntu and are skipped): it drains the node, reboots it into GRUB, runs a release
upgrade of 15–20 minutes and reboots it again. Nodes are converted one at a time,
but each is out of the cluster for the duration. Use `--limit` to choose which
nodes are converted when. Apart from this conversion, `--tags servers` reboots
no node that is in the cluster unless you pass `-e reboot_now=true`. See [](../explanations/ansible-roles.md).
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
the node carries live local-PV data (Prometheus on node04, Grafana on
node03 — see the "Local PV data paths are sacred"
rule in `CLAUDE.md`), expect fsck on boot and check the affected pods'
logs once the node returns.
:::

:::{note}
Don't `kubectl drain` first — the node is already unreachable, so the
drain will hang waiting for pods that can't be contacted. Just
power-cycle and let workloads reschedule (or come back, for DaemonSets
pinned to the node).
:::

(fence-a-dead-node)=
## Fail over from a dead node (fence)

Kubernetes cannot tell a dead node from one that is only cut off, so it
never force-removes the pods of a `NotReady` node. A `Recreate` Deployment
such as scrap's waits for ever for its old pod to go, and does not start
it anywhere else. Fencing tells Kubernetes the node is off. It uses the
[non-graceful node shutdown](https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/#non-graceful-node-shutdown)
taint, `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute`.

1. Make sure the node is **powered off**: `tpi power off -n <slot>` on
   the BMC, or unplug it. `NotReady` alone is not enough. A node that
   lost its network or its k3s agent may still be running its pods, and
   two copies of a single-writer app such as scrap corrupt its data.
2. Fence it. The recipe refuses a `Ready` node, warns, and asks you to
   type the node name to confirm it is powered off:

   ```bash
   just node-fence nuc2
   ```

3. Kubernetes force-deletes the node's pods and they restart on other
   nodes. scrap is serving again in about 1–2 minutes: its new pod
   restores the database from its Litestream replica
   (`kubectl -n scrap logs deploy/scrap -c db-init`). Nothing changes
   in git.
4. When the node is back and `Ready`, remove the fence. Pods that moved
   stay where they are.

   ```bash
   just node-unfence nuc2
   ```

Workloads pinned to the dead node, such as those on its `local-nvme`
PVs, stay `Pending` until it returns.

## Drain a node for maintenance

Before taking a node offline for hardware maintenance:

```bash
# Drain the node (evict pods, mark unschedulable)
kubectl drain node03 --ignore-daemonsets --delete-emptydir-data

# Perform maintenance...

# Uncordon the node (allow pods to schedule again)
kubectl uncordon node03
```

(move-a-local-nvme-pv)=
## Move a local-nvme PV to another node

Each `local-nvme` PV is pinned to one node by its `nodeAffinity`, which
Kubernetes does not let you change on an existing PV. To move one, for
example Grafana's from `node03` to `node02`, delete the PV through ArgoCD
and let it re-create it. The PV's policy is `Retain` and the data is a
directory on the host, so deleting the PV object does not delete any data.

1. In `kubernetes-services/values.yaml`, set the new `node` (and `path`, if
   that node keeps its data elsewhere) on the PV's `local_storage` entry.
   Make the same change to its `k8s_data_dirs` entry in
   `group_vars/all.yml`. Create the directory on the new node, either with
   `ansible-playbook pb_all.yml --tags servers --limit node02` (which also
   applies pending package updates) or by hand with the owner and mode from
   the `k8s_data_dirs` entry. Merge the change. Until step 3 the
   `local-storage` app shows a sync error for that PV, as it cannot change
   its node.
2. Delete the PVC and the pod that uses it. The PVC waits for the pod to
   go, and the StatefulSet then re-creates both. The new pod stays
   `Pending`, as the old PV still points at the old claim and node:

   ```bash
   kubectl -n monitoring delete pvc storage-grafana-prometheus-0 --wait=false
   kubectl -n monitoring delete pod grafana-prometheus-0
   ```

   To keep the data, copy the directory from the old node to the new one
   now, while nothing writes to it, keeping its owner and mode.
3. Delete the PV through ArgoCD and sync, so ArgoCD re-creates it with the
   new node. `argocd --core` uses the kube context's namespace, so set it
   to `argo-cd` first:

   ```bash
   kubectl config set-context --current --namespace=argo-cd
   argocd app delete-resource local-storage --core \
     --kind PersistentVolume --resource-name grafana-local
   argocd app sync local-storage --core
   kubectl config set-context --current --namespace=default
   ```

   In the ArgoCD UI, the same is: open `local-storage`, delete the PV,
   then **Sync**. `argocd app sync --replace` does not work instead: the
   ArgoCD server disables sync with replace.
4. Check that the PVC is `Bound` and the pod runs on the new node:
   `kubectl -n monitoring get pvc,pod -o wide`.

The old directory stays on the old node. Remove it by hand once the
workload runs from its new home.

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
