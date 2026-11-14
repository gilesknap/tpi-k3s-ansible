# Troubleshooting

Problems this cluster has actually had, or can have with the code as it
is, and their fixes. Fixes follow the cluster's one rule: a change to
anything ArgoCD manages goes through Git, not `kubectl`. Restarting a
workload, or asking ArgoCD to refresh, changes nothing in Git and is fine.

## Flashing

### USB error during `tpi flash`

**Symptom:** `Error occured during flashing: "USB"`

**Cause:** BMC firmware USB enumeration bug.

**Fix:** Power-cycle the entire Turing Pi board (not just the individual node).
After the BMC (`turingpi`, 192.168.1.80) reboots, retry the flash:

```bash
ansible-playbook pb_all.yml --tags flash -e do_flash=true
```

:::{tip}
To check that the USB device is visible before flashing:

```bash
# SSH to the BMC
ssh root@turingpi
tpi advanced msd --node <slot>
lsusb  # should show device ID 2207:350b for RK1
```
:::

### Node not reachable after flash

**Symptom:** SSH connection refused or timeout after `tpi flash` completes.

**Possible causes:**
1. Node hasn't finished booting: wait 60–90 seconds (an RK1's first boot of its
   staging OS takes a few minutes; watch it with `tpi uart -n <slot> get` on the BMC)
2. IP address changed: check that the node's name still resolves to the address
   the router gives it (node02 to node04 are 192.168.1.82 to .84)
3. `known_hosts` entry stale: delete the old entry and re-run:

```bash
ssh-keygen -R <node-ip>
ansible-playbook pb_all.yml --tags known_hosts
```

### Wrong data from `dd iflag=direct` on an RK1

**Symptom:** a checksum of a block device or file read with `dd iflag=direct` on an
RK1 does not match, but a second read, a buffered read, or GNU dd gives the right
answer. The bad bytes are the first 4 to 60 bytes of 128 KiB chunks.

**Cause:** a kernel bug on the RK3588 with kernel 7.0 (non-coherent PCIe DMA). An
`O_DIRECT` read over 128 KiB into a buffer that is not 64-byte aligned loses a
partial cache line at request boundaries to a swiotlb bounce and the cache
maintenance after it. Ubuntu 26.04's default `dd` is uutils, whose buffer is not
aligned. `O_DIRECT` writes, buffered reads and page-cache I/O (filesystems,
databases) are not affected: the data on disk is correct.

**Fix:** on RK1s, don't read block devices with `dd iflag=direct` (uutils). Use
GNU dd (`gnudd`, page-aligned buffers), or a buffered read after dropping the page
cache:

```bash
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
sudo head -c <bytes> /dev/nvme0n1 | sha256sum
```

## SSH / known_hosts

### ssh-keyscan found no host keys

**Symptom:** the `known_hosts` play fails one host with
`ssh-keyscan found no host keys for <node>: is it up and reachable on port 22?`

**Cause:** the node is down, its name does not resolve, or port 22 is not
reachable from where ansible runs. The other hosts are still updated.

**Fix:** check the node is up and `ssh-keyscan -T 5 <node>` returns keys,
then re-run `ansible-playbook pb_all.yml --tags known_hosts --limit <node>`.

### Race condition writing known_hosts

Parallel writes to one known_hosts file lose entries. The role's write tasks
use `throttle: 1`, so this is handled however the role is run; don't remove
the throttle when changing the role.

## Ansible

### `kubernetes.core` deprecation warning

**Symptom:**
```
[DEPRECATION WARNING]: The default value for option validate_certs will be changed
```

**Fix:** These are warnings, not errors. They come from the `kubernetes.core`
collection and don't affect functionality. Suppress with:

```bash
export ANSIBLE_DEPRECATION_WARNINGS=false
```

### Helm plugin breakage after upgrade

**Symptom:** Ansible's `helm` module fails with "Error: plugin X not found".

**Fix:** Clear the Helm cache and reinstall:

```bash
rm -rf ~/.cache/helm ~/.local/share/helm/plugins
ansible-playbook pb_all.yml --tags tools
```

## ArgoCD

### Application stuck in "Syncing"

**Symptom:** An application shows `Syncing` indefinitely at
`https://argocd.gkcluster.org`.

**Possible causes:**
1. Invalid manifest: check the **Events** tab, and the sync result, for
   validation errors
2. Resource hook timing out: check the hook pod's logs
3. A stale manifest cache: ArgoCD has not fetched the commit that fixes it

**Fix:** Push the fix, then make ArgoCD fetch it now instead of at its next
poll:

```bash
kubectl -n argo-cd annotate application <app-name> \
  argocd.argoproj.io/refresh=hard --overwrite
```

To stop a sync that will never finish, use **Terminate** on the
application's sync status in the ArgoCD UI. Do not delete or patch the
`Application`: the root app, `all-cluster-services`, owns it.

### Application stuck in "Running" operation (admission webhooks)

**Symptom:** An ArgoCD application shows a perpetual `Running` operation and
never reaches `Synced`, even though all resources are healthy.

**Cause:** Charts like `kube-prometheus-stack` and `ingress-nginx` include
admission webhook jobs with `helm.sh/hook-delete-policy: hook-succeeded`. The
job deletes itself before ArgoCD records completion, leaving the operation stuck.

**Fix:** The webhooks are disabled in both charts' values, in
`kubernetes-services/templates/`; keep them so, and do the same for a new
chart that shows this:

```yaml
# kube-prometheus-stack (grafana.yaml), under helm.valuesObject
prometheusOperator:
  admissionWebhooks:
    enabled: false

# ingress-nginx (ingress.yaml), under helm.valuesObject
controller:
  admissionWebhooks:
    enabled: false
```

An operation that is already stuck is ended with **Terminate** in the
ArgoCD UI.

### Application is `Unknown` with `InvalidSpecError` or `ComparisonError`

Three conditions, three fixes:

| Condition | Cause | Fix |
|-----------|-------|-----|
| `InvalidSpecError: application repo X is not permitted in project kubernetes` | the chart's repository is not in the AppProject's allow-list | add it to `sourceRepos` in `argo-cd/argo-project.yaml`, run `ansible-playbook pb_all.yml --tags cluster`, then restart the application controller (below) |
| `ComparisonError: failed to resolve revision ...: 403` or `404` | an OCI chart given with an `oci://` prefix, or a chart version that is not published | `repoURL` is the bare `ghcr.io/<org>/charts` with `chart: <name>`, and the same bare form in `sourceRepos`; check the version with `helm pull oci://ghcr.io/<org>/charts/<chart> --version <ver>` |
| `ComparisonError: values don't meet the specifications of the schema(s)` | the chart's `values.schema.json` rejects the `valuesObject` | fix the key in the template |

ArgoCD keeps showing an `InvalidSpecError` after the AppProject is fixed,
and a refresh does not clear it. Restart the application controller, which
validates again:

```bash
kubectl -n argo-cd delete pod argocd-application-controller-0
```

### App is Synced and Healthy but the pod has old settings

**Cause:** the change touched only a ConfigMap or Secret that the pod reads
as environment variables. Those are read when the pod starts, and unless
the chart puts a checksum of the config on the pod template, nothing
restarts it. The same holds after re-sealing a secret
({ref}`rotate-a-secret`).

**Fix:** compare, then restart the workload:

```bash
kubectl get cm -n <ns> <cm> -o jsonpath='{.data.<KEY>}'
kubectl exec -n <ns> <pod> -- printenv <KEY>
kubectl rollout restart -n <ns> deployment/<name>
```

## OAuth / Authentication

How the layers fit together (Cloudflare Access at the edge, then oauth2-proxy
or Dex in the cluster) is in {doc}`/explanations/architecture/authentication`.

### Any GitHub user can pass oauth2-proxy

**Symptom:** an account that is not in `admin_emails` reaches a service
gated by oauth2-proxy (Headlamp, Alertmanager): oauth2-proxy answers 202
instead of 403.

**Cause:** The oauth2-proxy Helm chart generates `email_domains = ["*"]` in
its default ConfigMap. This acts as an OR with `authenticatedEmailsFile`:
any email from any domain passes the domain check, so the restrictive email
file is silently ignored.

**Fix:** `kubernetes-services/templates/oauth2-proxy.yaml` sets
`email_domains = []` through `config.configFile`, so that only the emails in
`authenticatedEmailsFile` (rendered from `admin_emails`) are accepted. This
has regressed once: do not remove that override.

**Diagnosis:** Check the live ConfigMap:

```bash
kubectl get configmap oauth2-proxy -n oauth2-proxy -o yaml
# email_domains = ["*"] is the bug; it must be []
```

Watch auth decisions in real time:

```bash
kubectl logs -n oauth2-proxy deploy/oauth2-proxy -f
# 202 = allowed, 401 = no session, 403 = denied
```

### 403 after authenticating

**Symptom:** GitHub login succeeds, then oauth2-proxy returns 403; its log
shows `AuthFailure: unauthorized` with an email address.

**Cause:** The email on the GitHub account is not in `admin_emails` in
`kubernetes-services/values.yaml`. Or it was added, but the oauth2-proxy pod
has not restarted since (ArgoCD updates the ConfigMap, but that does not
always restart the pod).

**Fix:** Add the email to `admin_emails` through a PR if it is missing, then
restart oauth2-proxy:

```bash
kubectl rollout restart deployment/oauth2-proxy -n oauth2-proxy
```

A 403 page from Cloudflare instead (before any GitHub prompt from the
cluster) means the address is not in the Access policies: those are
`owner_emails` and `viewer_emails` in the Cloudflare code
({doc}`/how-to/cloudflare-as-code`).

### oauth2-proxy returns 403: CSRF cookie not found

**Symptom:** After GitHub authorisation, the oauth2-proxy callback returns
403 with "CSRF cookie not found" in the pod logs.

**Cause:** Stale oauth2-proxy cookies in the browser, from before a change
to the route or to the proxy's cookie secret. The CSRF cookie set during
`/oauth2/start` doesn't match the callback.

**Fix:** Clear all cookies for `*.gkcluster.org` (or use a private window)
and log in again. If the problem persists, restart oauth2-proxy:

```bash
kubectl rollout restart deployment/oauth2-proxy -n oauth2-proxy
```

### OIDC discovery returns HTML (Grafana, argocd-monitor or ArgoCD login fails)

**Symptom:** Logging in to Grafana, argocd-monitor or ArgoCD itself fails
with an error such as
`expected Content-Type = application/json, got "text/html"`, or "invalid
JSON" from the discovery document.

**Cause:** These services use ArgoCD's Dex, at
`https://argocd.gkcluster.org/api/dex`. From inside the cluster that name
resolves to Cloudflare, so the request leaves the cluster, comes back
through the tunnel, and is met by Cloudflare Access, which answers with its
HTML login page.

**Fix:** The `cluster` tag writes a split-horizon override: a
`coredns-custom` ConfigMap in `kube-system` whose `cluster-domain.server`
block makes `argocd.gkcluster.org` resolve to the ingress-nginx Service's
ClusterIP for pods, then restarts argocd-server. The task waits up to five
minutes for ArgoCD to create the ingress Service; if it timed out on a
fresh build, or the Service was re-created with a new ClusterIP, run the
tag again:

```bash
kubectl -n kube-system get configmap coredns-custom -o yaml   # is it there?
kubectl -n ingress-nginx get svc ingress-ingress-nginx-controller   # same ClusterIP?
ansible-playbook pb_all.yml --tags cluster
```

### Login works on the LAN but not from outside

**Cause:** The browser must reach `oauth2.gkcluster.org` to finish the
GitHub flow, so that name must be a tunnel route like the services it
protects. It is one of the `tunnel_services` in `cloudflare/locals.tf`;
check that it still is (`just cf-plan` shows no change), and that a new
service was added there too ({ref}`cf-add-service`).

## Browser

### Service shows blank page or stale UI after config change

**Symptom:** A web service (typically Headlamp) loads the page chrome but shows
no content, or displays an outdated version of the UI. Works correctly in
incognito/private mode.

**Cause:** Browsers aggressively cache JavaScript bundles, service workers, and
API responses. After a cluster reconfiguration or branch switch, the cached
assets may not match the current backend state.

**Fix (per-site):**

1. Open DevTools (`F12`) → **Application** tab → **Storage** → click
   **Clear site data** (tick all boxes including "Unregister service workers")
2. Hard-reload: `Ctrl+Shift+R` (Windows/Linux) or `Cmd+Shift+R` (macOS)

**Fix (reset all Chrome state for one site):**

1. Navigate to the affected URL
2. Click the padlock/tune icon in the address bar → **Site settings**
3. Click **Clear data** to remove cookies, cache, and local storage for that
   origin
4. Reload the page

**Fix (Chrome profile reset, if the above doesn't help):**

Chrome can cache redirect state in places that "Clear site data" doesn't reach.
A profile reset clears this without deleting bookmarks or saved passwords:

1. Navigate to ``chrome://settings/reset``
2. Click **Restore settings to their original defaults**
3. Reload the affected page

**Fix (other browsers):**

- Firefox: **Settings** → **Privacy** → **Clear Data** → **Cached Web Content**
- Try an incognito/private window first to confirm it's a caching issue

:::{tip}
When testing cluster changes that affect web UIs, use an incognito window first.
This keeps intermediate states out of the browser cache.
:::

## Local-nvme PVs and NFS backups

### Static PV not bound

**Symptom:** A pod stuck `Pending` with events like `no persistent volumes
available for this claim`.

**Check:** every PV of the `local-nvme` class (rendered by
`additions/local-storage/` from `local_storage` in
`kubernetes-services/values.yaml`) should be `Bound`:

```bash
kubectl get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,STATUS:.status.phase,CLAIM:.spec.claimRef.name | grep local-nvme
```

**Fix:** Check that the data directory exists on its node:
`/var/lib/k8s-data/grafana` and `/var/lib/k8s-data/prometheus` on node04,
`/home/k8s-data/<app>` on nuc2 (the `node` and `path` of the entry in
`k8s_data_dirs`, `group_vars/all.yml`, which must match `local_storage`).
The `k8s_data_dirs` role re-creates a missing directory; never create or
change anything under `/var/lib/k8s-data` by hand:

```bash
ansible-playbook pb_all.yml --tags k8s_data_dirs
```

### Pod `Pending` because its node is down

A workload on a `local-nvme` PV can run only on that PV's node (Grafana and
Prometheus on node04; Jellyfin and scrap's backup copy on nuc2). It waits
for the node; there is nothing to fix in the cluster. If the node is dead
for good, see {ref}`fence-a-dead-node` and {ref}`move-a-local-nvme-pv`.

### Restoring from a backup

The backups are under `/bigdisk/k8s-cluster/backups/` on the NAS (on the
NAS itself, `/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/`), and
encrypted on Google Drive. The restore recipes are in
{doc}`/how-to/backup-restore`.

## Networking

### Ingress returning 404 or 503

**Symptom:** `https://<service>.gkcluster.org` returns 404 Not Found or 503
Service Temporarily Unavailable from nginx.

**Checklist:**

1. **Service exists?** `kubectl get svc -n <namespace>`
2. **Endpoints populated?** `kubectl get endpoints -n <namespace> <svc-name>`
3. **Ingress resource correct?** `kubectl get ingress -n <namespace> -o yaml`
   (ingresses made by `additions/ingress` are named `<service>-ingress`)
4. **Is the request reaching nginx?** `dig <service>.gkcluster.org` returns
   Cloudflare addresses for every tunnelled name, not node addresses: the
   path is Cloudflare, cloudflared, then ingress-nginx. A 404 that is not
   nginx's means the hostname is not a tunnel route, and fell to the
   tunnel's catch-all ({ref}`cf-add-service`).

### Certificate not issuing

The cluster has one certificate: `wildcard-cert` in the `cert-manager`
namespace (issued by DNS-01 through Cloudflare), which ingress-nginx serves
as its default (`cert-manager/wildcard-tls`).

**Symptom:** `kubectl get cert -n cert-manager` shows `False` for Ready.

**Checklist:**

1. **Check cert-manager logs:**
   ```bash
   kubectl logs -n cert-manager deploy/cert-manager -f
   ```
2. **Check the CertificateRequest and Order:**
   ```bash
   kubectl get certificaterequest -A
   kubectl get order -A
   kubectl get challenge -A
   ```
3. **Cloudflare API token valid?** The SealedSecret in
   `additions/cert-manager/templates/cloudflare-api-token-secret.yaml` must
   decrypt to a token that can edit the zone's DNS: {ref}`cf-dns01-token`.

### `home-lan.gkcluster.org` does not resolve on the LAN (DNS rebinding protection)

**Symptom:** `nslookup home-lan.gkcluster.org` returns `NXDOMAIN` or no
address, while `nslookup home-lan.gkcluster.org 1.1.1.1` returns a
192.168.1.x address. The home page's LAN probe fails with it.

**Cause:** `home-lan` is a DNS-only record that points at a private
address (`dns_only_records` in the Cloudflare code); the home page probes
it to tell whether the browser is on the LAN. Routers and resolvers with
DNS rebinding protection drop answers that contain private addresses.
Every tunnelled name is a proxied record that resolves to Cloudflare's
addresses, so it is not affected.

**Fix:** allow the domain on the router. On OpenWrt (192.168.1.1), add
`gkcluster.org` to dnsmasq's rebind domain whitelist (Network, DHCP and
DNS), or add `list rebind_domain 'gkcluster.org'` to `/etc/config/dhcp`.

### A node cannot resolve `<node>.lan` or `k3s.lan`

**Cause:** the node's resolver was pointed at a public DNS server. The
`.lan` names, including the API name `k3s.lan`, exist only on the router.

**Fix:** point it back at the router, for example
`sudo resolvectl dns <interface> 192.168.1.1`.

## Cloudflare Tunnel

Tunnel routes, DNS records and Access apps are code in `cloudflare/`
({doc}`/how-to/cloudflare-as-code`): a fix made in the Cloudflare dashboard
is reverted by the next `just cf-apply`.

### Redirect loop through the tunnel

**Symptom:** Browser shows `ERR_TOO_MANY_REDIRECTS` on a tunnelled service.

**Cause:** cloudflared talks plain HTTP to ingress-nginx
(`http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local`,
`local.ingress_nginx` in `cloudflare/locals.tf`). An Ingress that forces an
SSL redirect answers every such request with a redirect to HTTPS, which
comes back the same way.

**Fix:** The Ingress must have `ssl-redirect: "false"`. The templates set
`ssl_redirect` from `enable_cloudflare_tunnel` (which is `true`); a new
service's template must do the same. Check:

```bash
kubectl get ingress -n <namespace> <service>-ingress -o yaml | grep ssl-redirect
```

If it shows `"true"`, check that ArgoCD has synced the app. A route in
`locals.tf` must also keep the `http://` scheme.

### Tunnel not connecting

**Symptom:** cloudflared pods are running but Cloudflare shows the tunnel
as down, and the public hostnames return a Cloudflare tunnel error.

**Checklist:**

1. **Pods running?** `kubectl get pods -n cloudflared` (two replicas)
2. **Logs show errors?** `kubectl logs -n cloudflared deployment/cloudflared | tail -30`
3. **Tunnel token valid?** The `cloudflared-credentials` Secret must exist
   (its SealedSecret decrypted) and hold the current token:
   ```bash
   kubectl get secret cloudflared-credentials -n cloudflared
   kubectl get sealedsecret -n cloudflared
   ```
   A `cf-apply` that rotated the tunnel secret needs the token sealed again
   with `just cf-seal-tunnel-token`, then a restart of cloudflared. Never
   print the token.
4. **Outbound connectivity?** The pods need to reach Cloudflare's edge on
   port 7844 (TCP and UDP).

### 502 Bad Gateway from Cloudflare

**Checklist:**

1. **Route goes to the ingress?** Every entry of `tunnel_services` uses the
   ingress controller's Service on port 80. A route straight to a service
   also bypasses oauth2-proxy.
2. **ingress-nginx running?** `kubectl get pods -n ingress-nginx`
3. **Ingress resource exists** for the hostname? `kubectl get ingress -A`

### New tunnel hostname won't resolve on the LAN

**Symptom:** After `just cf-apply` adds a service, LAN clients keep getting
`NXDOMAIN` for the new name. Public resolvers (`dig @1.1.1.1`) return the
record correctly.

**Cause:** Negative DNS caching. Before the record existed, the router,
`systemd-resolved` or the browser asked for the name, got `NXDOMAIN`, and
cached that answer for its TTL.

**Fix:** Flush the caches, nearest first:

```bash
# 1. Browser: a private window, or chrome://net-internals/#dns, "Clear host cache"

# 2. systemd-resolved on the client
sudo resolvectl flush-caches

# 3. The router (OpenWrt, 192.168.1.1): restart dnsmasq. This is the one
#    that tends to persist.
```

To confirm the negative cache is the cause, bypass the local resolver:

```bash
dig @1.1.1.1 <service>.gkcluster.org  # public resolver: answers
dig <service>.gkcluster.org           # local resolver: still NXDOMAIN
```

### `just cf-plan` fails: no Access app protects a hostname

**Cause:** the guard in `cloudflare/access_guard.tf` and `dns.tf`. A
hostname routed through the tunnel must be covered by an Access app (the
`*.gkcluster.org` wildcard covers names one label below the domain), or be
marked public on purpose.

**Fix:** see {ref}`cf-access-bypass`.

## NFS Mount Issues

### PVC stuck in Pending

**Symptom:** A PersistentVolumeClaim backed by the NAS stays in `Pending`,
or its pod stays in `ContainerCreating` with a mount error.

**Checklist:**

1. **NAS reachable?**
   ```bash
   kubectl run nfs-test --rm -it --restart=Never --image=busybox:1.37 -- ping -c 3 192.168.1.3
   ```
2. **Directory exists on the NAS?** The cluster creates none of the
   directories it mounts under `/bigdisk`, nor `/k8s-dynamic/stable`: they
   are made by hand ({doc}`/how-to/nas-setup`), with the owner the workload
   runs as. A missing directory fails the mount; a wrong owner shows up
   later as `Permission denied` in the pod.
3. **Static or dynamic?** Static NFS PVs (`k8s-cluster-nfs`, scrap's two,
   `jellyfin-media-nfs`, the Minecraft dashboard's three) have no
   StorageClass and bind by name: check `kubectl get pv`. Dynamic ones come
   from the `nfs-stable` (default) or `nfs-rwx` class: check
   `kubectl get sc` and the logs of `csi-nfs-controller` in the `nfs-csi`
   namespace.

### An `nfs-stable` PV stuck `Released`

Deleting a PVC whose name already has an archived folder makes the driver's
archive fail and retry. See {doc}`/how-to/nfs-stable-paths`.

## K3s Control Plane

The control plane is node02; `kubectl` reaches it as `k3s.lan`, a DNS record
on the router.

### API server unreachable

**Symptom:** `kubectl` commands fail with `connection refused` or time out
on port 6443.

**Checklist:**

1. **Name resolves to the control plane?** `dig +short k3s.lan` should
   return 192.168.1.82.
2. **K3s service running?**
   ```bash
   ssh ansible@node02 sudo systemctl status k3s
   ```
3. **Disk full?** etcd can fail if the node runs out of disk space:
   ```bash
   ssh ansible@node02 df -h /
   ```
4. **Certificates valid?** Check `/var/lib/rancher/k3s/server/tls/` on
   node02.

If node02 is dead, restore the control plane onto node03, the warm standby:
{doc}`/how-to/recover-control-plane`.

### etcd database too large

**Symptom:** K3s logs show `mvcc: database space exceeded`.

etcd has reached its quota (2 GiB, the default: the `k3s` role does not set
one), raised a `NOSPACE` alarm and refuses writes.

**Fix:** Take a snapshot, then restart K3s:

```bash
ssh ansible@node02
sudo k3s etcd-snapshot save --name manual-backup
sudo systemctl restart k3s
```

The API server compacts old revisions every five minutes, but that does not
shrink the file. When K3s starts it defragments the database, which does, and
then clears the alarm, so no `etcdctl` (the nodes have none) is needed. Check
the result of this restart, not an earlier one:

```bash
systemctl is-active k3s
sudo journalctl -u k3s --since "$(systemctl show k3s -p ExecMainStartTimestamp --value)" |
  grep 'after defragment'
```

The line reads `Datastore using <in use> of <file size> bytes after
defragment`. The database is normally tens of MB. If it is still near the
quota, the space may be history that was never compacted: defragmenting
frees only compacted revisions, and compaction is itself a write, so it can
have stopped while the alarm was up. With the alarm cleared the API server
compacts again, so wait ten minutes and restart K3s once more, then repeat
the check.

If it is still near the quota after that second restart, the space is live
data: look for an object kind with a runaway count (Events, Jobs,
ReplicaSets) and delete those. Deleting does not shrink the file either, so
finish in the same way: wait ten minutes for the compaction, restart K3s,
and check that the size has fallen and that a write works (for example
`kubectl annotate node node02 etcd-check=ok --overwrite`, then remove it
with `etcd-check-`).

### The nightly etcd backup alert fires

`K3sEtcdBackupFailed`, `K3sEtcdBackupStale` and the related alerts, and how
to check the job on node02 by hand: {ref}`etcd-offsite-backup`.

## Node OS

### AppArmor signal denials in containers (Ubuntu 25.04 and later)

**Symptom:** the node's kernel log fills with `apparmor="DENIED"
operation="signal"` entries for container processes, often `signal=urg`
from Go programs or `signal=hup` from nginx. Visible failures include
ingress-nginx never becoming ready because its reload fails with
`kill(...): permission denied`, and containers that ignore SIGTERM on
shutdown.

**Cause:** Ubuntu 25.04 and later set
`kernel.apparmor_restrict_unprivileged_unconfined=1`. Container processes
then run under the stacked label `cri-containerd.apparmor.d//&unconfined`,
which containerd's default AppArmor profile does not allow as a signal
peer ([containerd#14485](https://github.com/containerd/containerd/issues/14485)).

**Fix:** the `k3s` role installs a corrected `cri-containerd.apparmor.d`
profile in `/etc/apparmor.d/` on every node with AppArmor enabled, and
containerd uses it in place of its own. A small systemd unit,
`k3s-apparmor-profile.service`, reloads it at boot before k3s starts, so it
works even on images that mask `apparmor.service`. Running pods pick it up
without a restart. To apply it to a node on its own:

```bash
ansible-playbook pb_all.yml --tags apparmor --limit <node>
# then confirm no new denials
ssh <node> "sudo journalctl -k --since '-10 min' | grep -c 'apparmor=\"DENIED\" operation=\"signal\"'"
```

If the denials come back after a reboot, check the boot unit: a failure in
`systemctl status k3s-apparmor-profile` does not stop k3s, so containerd falls
back to its stock profile silently.

## Hardware

### RK1 module not detected in slot

**Symptom:** `tpi info` shows a slot as empty despite a module being seated
(the RK1s node02, node03 and node04 are in slots 2 to 4).

**Fix:**
1. Power off the board
2. Reseat the compute module firmly
3. Power on and check again:

```bash
ssh root@turingpi
tpi info
```
