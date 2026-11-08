# Recover the Control Plane

This runbook rebuilds a lost single-server control plane from the nightly
encrypted etcd backup on the NAS ({ref}`etcd-offsite-backup`). The workers
and their data are untouched. The restore can go onto the old control-plane
node, rebuilt, or onto any spare node. The examples use `node02`, an RK1
in Turing Pi slot 2, as the lost control plane and `node03` as the spare. The same procedure, planned, moves a healthy control plane to
another node: see [](#move-the-control-plane).

A restore takes the cluster back to the moment of the snapshot. Most
changes after that point come back by themselves, since ArgoCD re-syncs
from Git. Objects created by hand after the snapshot, such as a rotated
`admin-auth` Secret, are lost.

## When to use it

| Symptom | Action |
|---------|--------|
| API down, node boots and its disk is fine | `sudo systemctl restart k3s` on the node and read `journalctl -u k3s`. No restore. |
| etcd data damaged, OS fine | Restore from a local snapshot in `/var/lib/rancher/k3s/server/db/snapshots` (see {doc}`backup-restore`). No reflash. |
| Control-plane OS or storage lost: dead eMMC/SD, failed upgrade, accidental reflash | **This runbook.** |
| No usable backup, or several nodes lost | Full rebuild from Git: {doc}`reflash-rebuild` and {doc}`bootstrap-cluster`. |

The workers, the API server certificate and your kubeconfig all reach the
API through `k3s_api_name` in `group_vars/all.yml` (e.g. `k3s.lan`), a DNS
record on your router that points at the control plane. Wherever the control
plane comes back, point that record at it and the workers follow; nothing
has to keep the old node's IP. The `k3s` role refuses to run until the name
resolves to the `control_plane` node.

## Choose the target node

- **The old node, rebuilt.** Keeps its hostname and IP, so the DNS record
  needs no change. Use this when the hardware is fine and only its OS or
  disk was lost.
- **A spare node** (`node03` here). Use this when the old hardware is dead
  or slow to replace. A worker serves, but it loses its workloads while it
  changes role, and the `cluster` tag later taints it `NoSchedule`. Prefer a
  node that holds no `local-nvme` PV (`local_storage` in
  `kubernetes-services/values.yaml`): a pod pinned there by its PV cannot
  restart on it once it is tainted. `node03` holds Grafana's, which is
  acceptable while you recover, not as a permanent home.

For a spare node, set it as the control plane first, on a branch:

```yaml
# group_vars/all.yml
control_plane: node03
```

`just restore-control-plane` and the `k3s` role both read it.

## What you need

- The age private key for the backups, which you keep offline.
- SSH access to the NAS, or any machine that can mount the NFS share.
- A machine with this repository checked out and SSH access to the nodes
  as the `ansible` user. Your own machine is best, because the decrypted
  bundle holds every cluster Secret in plaintext.

:::{warning}
Do not run the `k3s` tag, or `pb_all.yml` without `--tags`, against the
control plane before the restore. The `k3s` role installs a brand-new
cluster with a new token and CA, and the workers would then refuse it.
:::

## 1. Get and decrypt the latest backup

The bundles are in `backups/etcd/` of the cluster share on the NAS, named
`k3s-etcd-<node>-<UTC time>.tar.age`. `LATEST` names the newest one.

```bash
mkdir -m 700 ~/k3s-restore && cd ~/k3s-restore
NAS_DIR=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/etcd
ssh nas cat "$NAS_DIR/LATEST"
bundle=$(ssh nas "sed -n 's/^bundle: //p' $NAS_DIR/LATEST")
scp "nas:$NAS_DIR/$bundle" "nas:$NAS_DIR/$bundle.sha256" .
sha256sum -c "$bundle.sha256"

age -d -i /path/to/k3s-etcd-backup.agekey "$bundle" | tar -x -C ~/k3s-restore
cat MANIFEST
```

The bundle unpacks to:

| File | Contents |
|------|----------|
| `snapshot/<name>` | etcd snapshot |
| `token` | k3s server token. A restore needs the token the snapshot was taken with. |
| `node-password` | the control plane's k3s node password, so it can re-register under its old name |
| `config.yaml` | the server's `/etc/rancher/k3s/config.yaml`, for reference |
| `MANIFEST` | node, time, k3s version and checksums |

`pre-upgrade/` holds the snapshot taken just before each automatic k3s
upgrade. Use one of those if the latest nightly was taken after a bad
upgrade.

## 2. Reflash and provision the node

**A spare node** needs no reflash. Remove its k3s agent instead; this keeps
`/etc/rancher/node/password` and the local PV data directories:

```bash
ssh ansible@node03 sudo k3s-agent-uninstall.sh
```

It also leaves the `k3s` binary and `/var/lib/rancher/k3s` behind (see
[](#k3s-uninstall-leaves-files-behind)). The restore copes with that.

**The old node:** power it off if it is half-alive, then flash and prepare
it, but stop before k3s:

```bash
ansible-playbook pb_all.yml --limit turingpi,node02 \
  --tags flash,known_hosts,servers -e flash_force=true
```

This runs `tpi flash` through the BMC (`roles/flash`), bootstraps the
`ansible` account, refreshes the SSH host keys and installs the base
packages. A node outside a Turing Pi is reinstalled by hand, then
`--tags known_hosts,servers`.

## 3. Restore etcd

From the repository checkout:

```bash
just restore-control-plane ~/k3s-restore/snapshot/<name> ~/k3s-restore/token
# without just: scripts/restore-control-plane <snapshot> <token>
```

The recipe restores onto `control_plane` (or `NODE=<node>`). It reads the
k3s version from `MANIFEST` and picks up `node-password` from the same
directory when the target is the node the bundle came from (the `node:`
line in `MANIFEST`); a spare node keeps its own. An older bundle without a
`node:` line restores no node password unless you pass it as the fourth
argument. It refuses a node that still runs the k3s agent. Run it with `DRY_RUN=1` first to
see exactly what it will do. It shows what it found on the node, then asks
you to type the node name. If k3s is running there or the node already
has etcd data, it also asks you to type `RESET <node>` (or set `FORCE=1`
to skip that second prompt). After that it:

1. installs the same k3s version as the snapshot without starting it
   (`INSTALL_K3S_SKIP_START=true`). k3s requires the snapshot's token
   and advises restoring onto the same minor version, so matching the
   exact version is the safe choice. It skips the install only when that
   version is already there *and* `k3s.service` exists: a former agent
   keeps the binary but has no server unit;
2. writes the server config from `roles/k3s/templates/k3s-server-config.yml.j2`,
   with `k3s_api_name` as its `tls-san`, and restores
   `/etc/rancher/node/password`;
3. writes the token to `/var/lib/rancher/k3s/server/token` (mode 0600).
   On a node that has never been a server, the reset otherwise fails with
   `server/token does not exist, please pass --token`, even with
   `--token-file`;
4. runs `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>
   --token-file=<token>`, which restores the snapshot, makes this node the
   only etcd member and exits. Any existing etcd data is moved to
   `db/etcd-old-<timestamp>`;
5. starts k3s normally, waits for the API server, and deletes its copy of
   the plaintext files. It deletes them on failure too; if even that
   cleanup fails, it prints the remote paths to delete by hand.

On a single server there are no etcd peers, so there is no `db` directory to
remove on other servers.

## 4. Point the API name at the new control plane

On a spare node, point the `k3s_api_name` DNS record at the new node's IP.
With an OpenWrt `dns_router`, that is one command, which also checks the
name resolves on the controller:

```bash
just k3s-api-dns 192.168.1.83
```

On another router, change the record by hand. Either way, check it from a
worker too:

```bash
getent hosts k3s.lan
ssh ansible@node04 getent hosts k3s.lan
```

Then refresh your kubeconfig and reinstall the backup timer:

```bash
ansible-playbook pb_all.yml --limit node03 --tags k3s
```

This is safe now: the role sees the restored server and skips the install.
It stops if the DNS record does not point at the new node yet.

## 5. Check the cluster

The workers have kept running their pods throughout. Their k3s agents
reconnect through `k3s_api_name` and trust the restored CA, so they rejoin
by themselves within a minute or two of the DNS change (allow for the
record's TTL). An agent that stays `NotReady` needs
`sudo systemctl restart k3s-agent`, or a reboot.

On a spare node, the restored cluster still lists the old control plane:
delete its Node object once it is not coming back as itself,
`kubectl delete node node02`.

```bash
just status                                   # nodes, ArgoCD apps, failing pods
kubectl get nodes                             # all Ready
kubectl -n argo-cd get applications           # Synced / Healthy
kubectl get sealedsecrets -A                  # every SYNCED is True
kubectl -n kube-system get deploy coredns     # available
kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup kubernetes.default
just etcd-backup-now                          # a new bundle reaches the NAS
```

If something is off:

- **A worker stays `NotReady`:** check `getent hosts k3s.lan` on it, then
  run `sudo systemctl restart k3s-agent` on it.
- **A worker still dials the old IP:** it joined before `k3s_api_name`
  existed. Fix it by hand on the worker:

  ```bash
  sudo sed -i "s|^K3S_URL=.*|K3S_URL='https://k3s.lan:6443'|" \
    /etc/systemd/system/k3s-agent.service.env
  sudo systemctl restart k3s-agent
  ```

  Don't use `--tags k3s --limit <worker>` for this while the worker is
  `NotReady`: the role then deletes its Node object, uninstalls the agent
  and reinstalls it. That works, but it is a full rejoin, not a URL fix.
  Once the worker is `Ready`, the role rewrites `K3S_URL` in place.
- **The control plane stays `NotReady` with "Node password rejected"** (no
  `node-password` restored): run
  `kubectl -n kube-system delete secret <node>.node-password.k3s`.
- **SealedSecrets fail with `no key could decrypt secret`:** the sealing key
  was rotated after the snapshot. Restore the key from your sealed-secrets
  key backup ({doc}`backup-restore`) or re-seal ({doc}`manage-sealed-secrets`).
- **DaemonSet pods on a former worker are unreachable** (e.g. a readiness
  probe that times out): the restored cluster still holds the pods that ran
  on the new control plane while it was an agent, and they can come back
  with IPs from its old podCIDR. The node re-registers with a new one, so
  nothing routes to those IPs. Compare the two, and delete each pod whose
  IP is outside the node's podCIDR (pods on the host network show the node
  IP and are fine); its DaemonSet re-creates it:

  ```bash
  kubectl get node node03 -o jsonpath='{.spec.podCIDR}{"\n"}'
  kubectl get pods -A -o wide --field-selector spec.nodeName=node03
  kubectl -n <namespace> delete pod <pod>
  ```

- **An ArgoCD app is stuck:** `just argocd-sync`.

## 6. Fallback: rebuild from Git

If no bundle decrypts, or the restore fails, rebuild the cluster from Git
({doc}`reflash-rebuild`, {doc}`bootstrap-cluster`) and restore stateful data
from the NAS ({doc}`backup-restore`). The `local-nvme` data directories on
the workers survive a rebuild.

## Move the control plane

Moving a healthy control plane to another node is the same restore, planned:
a fresh snapshot, then a short API outage while the new node takes over.
Workloads keep running throughout. Moving an RK1 control plane to another
RK1 took about 15 minutes of API downtime, from stopping the old server to
the DNS change. Before you start, the `k3s_api_name`
record must exist and every agent must already use it (run
`ansible-playbook pb_all.yml --tags k3s` once and check with
`sudo grep K3S_URL /etc/systemd/system/k3s-agent.service.env`).

1. Pick the new node as in [](#choose-the-target-node); a node with no
   `local-nvme` PV is best. Move any PV it holds first: re-pin it in
   `local_storage` and `k8s_data_dirs` and copy its data (see "Move a
   local-nvme PV to another node" in {doc}`node-operations`).
2. Drain it and remove its agent:

   ```bash
   kubectl drain node03 --ignore-daemonsets --delete-emptydir-data
   ssh ansible@node03 sudo k3s-agent-uninstall.sh
   kubectl delete node node03
   ```

3. Take a backup, then stop the old server at once, so nothing changes
   after the snapshot:

   ```bash
   just etcd-backup-now
   ssh ansible@node02 'sudo systemctl disable --now k3s-etcd-backup.timer k3s'
   ```

4. Fetch and decrypt that bundle ([step 1](#1-get-and-decrypt-the-latest-backup)).
5. Set `control_plane: node03` in `group_vars/all.yml` and restore
   ([step 3](#3-restore-etcd)).
6. Point the DNS record at node03 (`just k3s-api-dns 192.168.1.83`) and run
   the `k3s` tag on it
   ([step 4](#4-point-the-api-name-at-the-new-control-plane)), then check the
   cluster ([step 5](#5-check-the-cluster)). The agents rejoin by themselves
   within a minute or two. Look out for unreachable DaemonSet pods on the
   new node, left over from its time as an agent (see the troubleshooting
   list in step 5).
7. Remove the old server, whether you retire node02 or keep it as a
   worker, so `k3s.service` doesn't linger:

   ```bash
   ssh ansible@node02 sudo k3s-uninstall.sh
   kubectl delete node node02
   ```

   This leaves the old etcd data, which holds every cluster Secret, on the
   node ([below](#k3s-uninstall-leaves-files-behind)); delete it by hand.
   To keep the node as a worker, then run
   `ansible-playbook pb_all.yml --tags k3s --limit node02`.
8. Taint the new control plane with
   `ansible-playbook pb_all.yml --tags cluster`, and update anything else
   that names the old node's IP, such as a Cloudflare SSH tunnel route.
9. Commit the `control_plane` change and merge it.

### k3s uninstall leaves files behind

`k3s-uninstall.sh` and `k3s-agent-uninstall.sh` remove their own service,
then stop early, with `Additional k3s services installed, skipping
uninstall of k3s`, if any other `/etc/systemd/system/k3s*.service` remains.
This repository installs `k3s-apparmor-profile.service` on every node and
`k3s-etcd-backup.service` on the control plane, so on these nodes the
scripts always stop there. They leave the `k3s` binary, the `kubectl`,
`crictl` and `ctr` links, `k3s-killall.sh`, `/etc/rancher/k3s` and all of
`/var/lib/rancher/k3s`, and they delete themselves.

That is harmless on a former agent: the restore installs over it. On a
former server, `/var/lib/rancher/k3s/server` still holds the old etcd
database and token. Remove it once the new control plane is healthy:

```bash
ssh ansible@node02 'sudo rm -f /etc/systemd/system/k3s-etcd-backup.* &&
  sudo systemctl daemon-reload &&
  sudo rm -rf /var/lib/rancher/k3s/server /etc/rancher/k3s'
```
