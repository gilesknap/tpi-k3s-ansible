# Node operations

Runbooks for the cluster's six nodes: package updates, shutdown and reboot,
power-cycling through the BMC, fencing, draining, moving a local PV, and
adding or removing a node. Routine OS updates and reboots are automatic
({doc}`/explanations/upgrade-model`), so most of this page is for the
exceptions. {doc}`/explanations/architecture/hardware` describes the nodes
themselves.

| Node | Address | What to remember before touching it |
|------|---------|--------------------------------------|
| `node02` | 192.168.1.82 | Control plane and etcd. The Kubernetes API is down while it is; running pods carry on. |
| `node03` | 192.168.1.83 | Warm-standby control plane; an ordinary worker until it is needed. |
| `node04` | 192.168.1.84 | Holds the Prometheus and Grafana `local-nvme` PVs: monitoring is down while it is. |
| `nuc1` | 192.168.1.91 | Worker with nothing pinned to it. |
| `nuc2` | 192.168.1.92 | Holds Jellyfin, every Minecraft world and scrap's backup copy. |
| `ws03` | 192.168.1.10 | The owner's workstation. No automation reboots it; see [](#what-never-applies-to-ws03). |

`node02`, `node03` and `node04` are RK1 modules in slots 2 to 4 of the
Turing Pi, whose BMC is `turingpi` (192.168.1.80).

## Apply package updates to nodes

The `update_packages` role is part of the `servers` play — **not** a tag of its own.
To run package updates (e.g. after adding a new package to the role):

```bash
# Chosen nodes
ansible-playbook pb_all.yml --tags servers --limit node03,node04

# Every node
ansible-playbook pb_all.yml --tags servers

# Also reboot now the nodes that need it: drained, one at a time
ansible-playbook pb_all.yml --tags servers -e reboot_now=true
```

`update_packages` does not reboot a node that is in the cluster. If an upgrade
needs a reboot it leaves `/var/run/reboot-required` for kured, which drains and
reboots the node in the nightly window, and says so in the output. With
`-e reboot_now=true` the nodes that need it are drained, rebooted and uncordoned
one at a time instead. A node not yet running K3s is rebooted straight away, and
`ws03` is never rebooted: the play only warns that it needs one. See
{doc}`/explanations/upgrade-model`.

:::{note}
`--tags update_packages` will silently do nothing — the correct tag is `servers`,
which runs the `move_fs`, `rk1_os`, `update_packages` and `k8s_data_dirs` roles.
:::

:::{warning}
`--tags servers` also runs the `rk1_os` role, which converts an RK1 still on
the old ubuntu-rockchip vendor image to stock Ubuntu: it drains the node,
reboots it into GRUB, runs a release upgrade of 15–20 minutes and reboots it
again, one node at a time. All three RK1s here already run stock Ubuntu
26.04, so the role has nothing left to convert. Apart from that
conversion, `--tags servers` reboots no node that is in the cluster unless
you pass `-e reboot_now=true`. See {doc}`/explanations/ansible-roles`.
:::

## Shut down or reboot a node

These ad-hoc commands do not drain the node first. For a planned reboot of
one node, drain it ([](#drain-a-node-for-maintenance)) or let
`-e reboot_now=true` above do the drain, reboot and uncordon.

```bash
# Shut down
ansible node03 -a "/sbin/shutdown now" --become

# Reboot
ansible node03 -m reboot --become
```

### The power button on nuc1 and nuc2

A short press of the power button on `nuc1` or `nuc2` does nothing, so a
button knocked while swapping cables no longer shuts the node down. Holding
it for about 4 seconds still cuts the power, with no drain and no clean
shutdown: shut a node down with the commands above instead. This is
`power_key_ignore: true` in `hosts.yml`, applied by `update_packages`
(`--tags servers`, or `--tags power_key` alone); see
{doc}`/explanations/ansible-roles`. `gknas` has the same setting
({doc}`/how-to/nas-ubuntu-zfs`). `ws03` and the RK1s are left alone.

## Shut down or reboot the whole cluster

For a power cut or moving the hardware. The pattern leaves `ws03` out:

```bash
# Shut down
ansible 'all_nodes:!ws03' -a "/sbin/shutdown now" -f 10 --become

# Reboot
ansible 'all_nodes:!ws03' -m reboot -f 10 --become
```

Every node goes down at once, so nothing is drained and everything is
unavailable until `node02` and the workers are back. The nodes come back by
themselves and need no playbook run.

## Hard power-cycle a Turing Pi node via the BMC

Use this when an RK1 is `NotReady` and SSH times out. The graceful
`ansible -m reboot` above needs a working `sshd` on the target, so it
cannot recover an unreachable node.

The BMC is reachable as `root@turingpi`. Each slot maps to a node through
`slot_num` in `hosts.yml`: `node02` is slot 2, `node03` slot 3 and `node04`
slot 4 (slot 1 is not used). `nuc1`, `nuc2` and `ws03` are not on the
BMC: power them with their own buttons.

```bash
# Inspect what the BMC thinks of all four slots
ssh root@turingpi 'tpi power status'

# Power-cycle a single node (off → wait → on)
ssh root@turingpi 'tpi power off -n 4 && sleep 15 && tpi power on -n 4'

# Wait for it to rejoin the cluster
kubectl get nodes -w
```

:::{warning}
A hard power-cycle is an unclean shutdown for any in-flight writes. `node04`
carries live local PV data (Prometheus and Grafana, under
`/var/lib/k8s-data`): expect a filesystem check on boot and read the
affected pods' logs once the node returns. Power-cycling `node02` takes the
Kubernetes API down until it is back.
:::

:::{note}
Don't `kubectl drain` first: the node is already unreachable, so the
drain hangs waiting for pods that can't be contacted. Power-cycle it and
let its pods come back with it. If the node is not coming back, power it
off and fence it instead (next section).
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
   the BMC for an RK1, the power button or the plug for a NUC. `NotReady` alone is not enough. A node that
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

The recipes are `scripts/node-fence fence|unfence <node>`. Workloads pinned
to the dead node stay `Pending` until it returns: Prometheus and Grafana
for `node04`; Jellyfin and the Minecraft worlds for `nuc2`. Fencing `node02`
is not possible, since the API it would be done through runs there: see
{doc}`recover-control-plane`.

## Drain a node for maintenance

Before taking a node offline for hardware maintenance:

```bash
# Drain the node (evict pods, mark unschedulable)
kubectl drain node03 --ignore-daemonsets --delete-emptydir-data

# Perform maintenance...

# Uncordon the node (allow pods to schedule again)
kubectl uncordon node03
```

CoreDNS, oauth2-proxy and cloudflared each run two replicas with a
PodDisruptionBudget, so draining one node leaves them serving; the Gateway's
Envoy is the `cilium-envoy` DaemonSet, which a drain leaves running. Drain
one node at a time. scrap restarts on another node, restoring its database
from its Litestream replica. Pods bound to a `local-nvme` PV on the drained
node (Prometheus and Grafana on `node04`, Jellyfin on `nuc2`) and the
Minecraft worlds on `nuc2` stay down until it is uncordoned.

(move-a-local-nvme-pv)=
## Move a local-nvme PV to another node

Each `local-nvme` PV is pinned to one node by its `nodeAffinity`, which
Kubernetes does not let you change on an existing PV. To move one, for
example Grafana's from `node04` to `nuc1`, delete the PV through ArgoCD
and let it re-create it. The PV's policy is `Retain` and the data is a
directory on the host, so deleting the PV object does not delete any data.

1. In `kubernetes-services/values.yaml`, set the new `node` (and `path`, if
   that node keeps its data elsewhere) on the PV's `local_storage` entry.
   Make the same change to its `k8s_data_dirs` entry in
   `group_vars/all.yml`. On the branch, let the `k8s_data_dirs` role
   create the directory on the new node, with that entry's owner, group
   and mode. Do not create it by hand:

   ```bash
   ansible-playbook pb_all.yml --tags k8s_data_dirs --limit nuc1
   ```

   The tag runs only that role. `--tags servers` would also run
   `move_fs`, `rk1_os` and `update_packages`.

   If the workload has a backup ({doc}`/how-to/backup-restore`), take a fresh one
   now, while it still runs on the old node.

   Merge the change into the branch ArgoCD tracks (`repo_branch`, normally
   `main`), then hard-refresh the parent app, `all-cluster-services`, so it
   re-reads that branch straight away:

   ```bash
   kubectl -n argo-cd annotate application all-cluster-services \
     argocd.argoproj.io/refresh=hard --overwrite
   ```

   The child apps, such as `local-storage` and `backups`, take their values
   from the parent. Refreshing only a child leaves it on the parent's old
   commit, still with the old node. Wait until the `local-storage` app
   shows a sync error for that PV, as it cannot change its node: that shows
   it has the new values. Do not go on before then, or step 3 re-creates
   the PV on the old node. The error stays until step 3.
2. Delete the PVC and the pod that uses it. The PVC waits for the pod to
   go, and the StatefulSet then re-creates both. The new pod stays
   `Pending`, as the old PV still points at the old claim and node:

   ```bash
   kubectl -n monitoring delete pvc storage-grafana-prometheus-0 --wait=false
   kubectl -n monitoring delete pod grafana-prometheus-0
   ```

   The new node's directory starts empty. Bring the data across with the
   workload's own backup and restore, not by copying files under the data
   paths by hand: nothing but the `k8s_data_dirs` role writes under
   `/var/lib/k8s-data` on an RK1 (a hard rule in `CLAUDE.md`).
3. Delete the PV through ArgoCD and sync, so ArgoCD re-creates it with the
   new node. `argocd --core` uses the kube context's namespace, so set it
   to `argo-cd` first:

   ```bash
   kubectl config set-context --current --namespace=argo-cd
   argocd app delete-resource local-storage --core \
     --kind PersistentVolume --resource-name grafana-local
   argocd app sync local-storage --core
   ```

   Then set the namespace back to the one you had before, if it was not
   `argo-cd`.

   The sync can fail with `another operation is already in progress`,
   while auto-sync retries the app. That is usually fine: the auto-sync
   re-creates the PV once `delete-resource` has removed it. If that
   operation ends failed instead (its retries ran out before the PV was
   gone), ArgoCD does not retry the same revision by itself: run the sync
   again once it has finished.

   In the ArgoCD UI, the same is: open `local-storage`, delete the PV,
   then **Sync**. `argocd app sync --replace` does not work instead: the
   ArgoCD server disables sync with replace.
4. Check that the PVC is `Bound` and the pod runs on the new node:
   `kubectl -n monitoring get pvc,pod -o wide`.

The old directory stays on the old node, as a fallback. Do not remove it
by hand: only `pb_decommission.yml -e wipe_local_data=true` or a re-flash
removes it ({doc}`/how-to/reflash-rebuild`).

A new workload that needs a `local-nvme` volume gets its own PV and its own
node, never a shared pool: add an entry to `local_storage` and to
`k8s_data_dirs`, as above. {doc}`/explanations/architecture/storage` has
the reasoning.

## Add a node

The `/add-node` command in Claude Code walks through this checklist, asking
for the details and making the edits. `nuc1` was the last node added this
way; the examples use it. The node needs a fixed address and a name on the
router, since the `known_hosts` role looks it up as `<node>.lan`: give it
`lan_ip` in step 1 and push it to the router with `just router-dhcp`
({doc}`/how-to/router-dhcp`), before the node first boots. A node
outside the Turing Pi also needs Ubuntu installed (24.04 or later). Install
an x86 node from the install stick ({doc}`/how-to/install-stick`): give it
`install_profile`, `install_disk_serial` and `install_machine_macs` in
step 1, rebuild the stick and install it. The stick creates the `ansible`
account with both keys, so the node skips steps 3 and 5. A node installed some other way needs a login
with sudo for step 3. A new RK1 needs neither: the flash in step 4 installs
Ubuntu and creates the `ansible` account, so it also skips steps 3 and 5.

1. **Inventory.** Add the node to `hosts.yml` under `extra_nodes`, with
   only the variables it needs:

   ```yaml
   extra_nodes:
     hosts:
       ws03:
         nvidia_gpu_node: true # installs the NVIDIA container toolkit
         workstation: true # taint NoSchedule, never rebooted or upgraded for you
       nuc2:
         node_ip: 192.168.1.92 # multi-homed: force K3s onto this subnet
         intel_gpu_node: true # Iris Xe: runs the Intel GPU device plugin
       nuc1: # single NIC
         lan_ip: 192.168.1.91 # reserved on the router for the name nuc1
         install_profile: desktop # the install stick's entry
         install_disk_serial: S5GFNG0N302036V
         install_machine_macs: ["1c:69:7a:61:65:d4"]
   ```

   `install_profile`, `install_disk_serial` and `install_machine_macs` give
   the node its entry on the install stick. Read the serial with
   `lsblk -o NAME,SIZE,MODEL,SERIAL` and the MACs with
   `cat /sys/class/net/*/address`; for a machine with no OS yet, see
   [](install-stick.md#new-hardware). A node with more disks lists their
   fstab entries in `extra_mounts` (see `nuc2` in `hosts.yml`); step 4
   mounts them.

   A node with interfaces on two subnets needs `node_ip`. Without it K3s
   may advertise the default-route interface's address, and Cilium's tunnel
   to the node, so cross-node pod networking, fails. A new RK1 goes under
   `turingpi_nodes` instead, with `slot_num`, `type: rk1` and `root_dev`.
2. **Sandbox allow-list.** The claude-sandbox blocks every private address
   that is not listed, so add the node's IP as an `allow-ip` line in
   `.devcontainer/claude-sandbox.conf`, then apply it from a devcontainer
   terminal (it takes effect at the next sandbox launch):

   ```bash
   just sandbox-conf
   ```

3. **Ansible access** (not for an RK1 or a node from the install stick:
   the playbook only targets `extra_nodes`, and the stick already did
   this). `pb_add_nodes.yml` creates the `ansible` account
   with the key from `pub_keys/ansible_rsa.pub` and passwordless sudo. Run
   it yourself in a devcontainer terminal: `-K` prompts for a sudo
   password, which Claude Code's shell cannot answer.

   ```bash
   ansible-playbook pb_add_nodes.yml --limit nuc1 -e ansible_user=<existing-user> -K
   ansible nuc1 -m ping
   ```

   The existing user must be passed with `-e`, not `-u`: `hosts.yml` sets
   `ansible_user` for `extra_nodes` to the `ansible` account, which does not
   exist on the new node yet and overrides `-u`. Re-running the playbook on
   a node that is already set up is safe; it adds the key without removing
   others.
4. **Join the cluster.**

   ```bash
   ansible-playbook pb_all.yml --limit nuc1 --tags known_hosts,servers,k3s
   kubectl get nodes
   ```

   This records the host keys, dist-upgrades the node (rebooting it if
   needed, as it is not in the cluster yet) and installs the K3s agent at
   the version `node02` runs.

   A new RK1 has no OS to log in to, so it is flashed first, in the same
   run. The flash role runs on the BMC, which goes in the limit, and there
   are no `--tags`:

   ```bash
   ansible-playbook pb_all.yml --limit turingpi,<node> -e do_flash=true
   ```

   `do_flash` flashes a node that does not answer SSH, then the rest of
   the run joins it as above.
5. **Claude's SSH key.** Add the sandbox's key to the node's `ansible`
   account, so Claude sessions can run Ansible against it. Skip this for a
   freshly flashed RK1 or a node from the install stick, whose install
   already carries the key:

   ```bash
   ansible-playbook pb_all.yml --tags claude_key --limit nuc1
   ```

6. **Minecraft RCON exception list.** Every node's IP is in the `except`
   list of `minecraft.worlds.rcon_allowed_cidrs` in
   `kubernetes-services/values.yaml`, so its host cannot reach a world's
   RCON port. Add the new node as a `/32`. Two nodes' hosts stay allowed on
   purpose, so RCON clients can run on them: `nuc2`, where the worlds run,
   and `ws03`, whose taint keeps workload pods off it and which is admitted
   by name through `minecraft.worlds.rcon_allowed_nodes`.
7. **Commit.** `hosts.yml`, `claude-sandbox.conf` and `values.yaml` go
   through a branch and a PR like any other change
   ({doc}`/how-to/work-in-branches`).

Nothing else needs adjusting. The control-plane taints are applied by node
name, kured and the device-plugin DaemonSets follow labels and taints, and
there is no replicated storage to rebalance: the node holds no volumes
until a workload is given a `local-nvme` PV pinned to it.

## Remove a worker node

`node02` cannot be removed this way: move the control plane first
([](recover-control-plane.md#move-the-control-plane)).

1. Check that nothing is pinned to the node: no `local_storage` entry in
   `kubernetes-services/values.yaml` names it (move the PV first,
   {ref}`move-a-local-nvme-pv`), and it is not `minecraft.worlds.node`.
2. Drain it and delete it from Kubernetes:

   ```bash
   kubectl drain nuc1 --ignore-daemonsets --delete-emptydir-data
   kubectl delete node nuc1
   ```

3. Uninstall the K3s agent:

   ```bash
   ssh ansible@nuc1 sudo k3s-agent-uninstall.sh
   ```

   The script stops before its full cleanup, because this repository's
   `k3s-apparmor-profile.service` is still installed: see
   [](recover-control-plane.md#k3s-uninstall-leaves-files-behind).
4. Remove the node from `hosts.yml`, its `allow-ip` line from
   `.devcontainer/claude-sandbox.conf`, its entry in `rcon_allowed_cidrs`
   (and in `rcon_allowed_nodes`, if any), and `standby_control_plane` in `group_vars/all.yml` if it named this
   node. Commit the change.

(what-never-applies-to-ws03)=
## What never applies to ws03

`ws03` is a desktop in daily use that also lends its NVIDIA GPU to the
cluster ({doc}`/explanations/decisions/0005-ws03-workstation-taint`). It is
`workstation: true` in `hosts.yml`, which takes it out of every automated
disruption:

- kured does not run on it, so it is never rebooted in the nightly window.
- `update_packages` never reboots it, even with `-e reboot_now=true`, and
  leaves its unattended-upgrades policy alone.
- The K3s upgrade Plans do not select it. Upgrade its agent by hand with
  `just upgrade-workstation ws03` ({doc}`/how-to/upgrade-k3s`).
- Its `workstation=true:NoSchedule` taint keeps ordinary pods off it, so
  draining it moves almost nothing.

Reboot it yourself when it suits. Leave it out of whole-cluster shutdown
and reboot commands, as above.

## Run an ad-hoc command on the nodes

```bash
# Disk usage on the cluster's nodes
ansible all_nodes -a "df -h" --become

# K3s agent status on the workers
ansible 'all_nodes:!node02' -a "systemctl is-active k3s-agent" --become

# Run a role standalone
ansible all_nodes -m include_role -a name=known_hosts
```

Inside the claude-sandbox, add `--private-key /root/.config/claude-ssh/id_ed25519`
to `ansible` and `ansible-playbook`, and `-i` with the same path to `ssh`:
nothing passes that key automatically.
