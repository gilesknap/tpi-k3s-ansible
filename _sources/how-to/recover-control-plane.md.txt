# Recover the Control Plane

This runbook rebuilds a lost single-server control plane from the nightly
encrypted etcd backup on the NAS ({ref}`etcd-offsite-backup`). The workers
and their data are untouched. The examples use `node01`, a Raspberry Pi CM4
in Turing Pi slot 1, as the control plane.

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

The control plane must come back with the **same hostname and IP**
(192.168.1.81 for node01), because the workers connect to that address.
Keep a DHCP reservation for it; a replacement module needs the reservation
moved to its MAC address.

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

Power the node off if it is half-alive, then flash and prepare it, but stop
before k3s:

```bash
ansible-playbook pb_all.yml --limit turingpi,node01 \
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

The recipe reads the k3s version from `MANIFEST` and picks up
`node-password` from the same directory. Run it with `DRY_RUN=1` first to
see exactly what it will do. It shows what it found on the node, then asks
you to type the node name. If k3s is running there or the node already
has etcd data, it also asks you to type `RESET <node>` (or set `FORCE=1`
to skip that second prompt). After that it:

1. installs the same k3s version as the snapshot without starting it
   (`INSTALL_K3S_SKIP_START=true`). k3s requires the snapshot's token
   and advises restoring onto the same minor version, so matching the
   exact version is the safe choice;
2. writes the server config from `roles/k3s/templates/k3s-server-config.yml.j2`
   and restores `/etc/rancher/node/password`;
3. runs `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>
   --token-file=<token>`, which restores the snapshot, makes this node the
   only etcd member and exits. Any existing etcd data is moved to
   `db/etcd-old-<timestamp>`;
4. starts k3s normally, waits for the API server, and deletes its copy of
   the plaintext files. It deletes them on failure too; if even that
   cleanup fails, it prints the remote paths to delete by hand.

On a single server there are no etcd peers, so there is no `db` directory to
remove on other servers.

Then refresh your kubeconfig and reinstall the backup timer:

```bash
ansible-playbook pb_all.yml --limit node01 --tags k3s
```

This is safe now: the role sees the restored server and skips the install.

## 4. Check the cluster

The workers have kept running their pods throughout. Their k3s agents
reconnect to the same IP and trust the restored CA, so they rejoin by
themselves within a minute or two.

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

- **A worker stays `NotReady`:** run `sudo systemctl restart k3s-agent` on it.
- **The control plane stays `NotReady` with "Node password rejected"** (no
  `node-password` in the bundle): run
  `kubectl -n kube-system delete secret node01.node-password.k3s`.
- **SealedSecrets fail with `no key could decrypt secret`:** the sealing key
  was rotated after the snapshot. Restore the key from your sealed-secrets
  key backup ({doc}`backup-restore`) or re-seal ({doc}`manage-sealed-secrets`).
- **An ArgoCD app is stuck:** `just argocd-sync`.

## 5. Fallback: rebuild from Git

If no bundle decrypts, or the restore fails, rebuild the cluster from Git
({doc}`reflash-rebuild`, {doc}`bootstrap-cluster`) and restore stateful data
from the NAS ({doc}`backup-restore`). The `local-nvme` data directories on
the workers survive a rebuild.
