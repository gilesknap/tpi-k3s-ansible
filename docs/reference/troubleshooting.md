# Troubleshooting

Common issues and their solutions.

## Flashing

### USB error during `tpi flash`

**Symptom:** `Error occured during flashing: "USB"`

**Cause:** BMC firmware USB enumeration bug.

**Fix:** Power-cycle the entire Turing Pi board (not just the individual node).
After the BMC reboots, retry the flash:

```bash
ansible-playbook pb_all.yml --tags flash -e do_flash=true
```

:::{tip}
You can verify the USB device is visible before flashing:

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
1. Node hasn't finished booting — wait 60–90 seconds
2. IP address changed — check `hosts.yml` matches the DHCP lease or static IP
3. `known_hosts` entry stale — delete the old entry and re-run:

```bash
ssh-keygen -R <node-ip>
ansible-playbook pb_all.yml --tags known_hosts
```

## SSH / known_hosts

### Race condition writing known_hosts

**Symptom:** `known_hosts` task fails with concurrent write errors.

**Cause:** The `known_hosts` play must run `serial: 1`. Parallel writes to
`~/.ssh/known_hosts` corrupt the file.

**Fix:** This is already handled in the playbook. If you see this error, check
that you haven't overridden `serial` in a custom run.

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

**Symptom:** An application shows `Syncing` indefinitely in the ArgoCD UI.

**Possible causes:**
1. Invalid manifest — check the **Events** tab for validation errors
2. Namespace doesn't exist — ArgoCD creates namespaces only if `CreateNamespace=true`
   is set in sync options (this project sets it for all apps)
3. Resource hooks timing out — check hook pod logs

**Fix:**

```bash
# Force a hard refresh
kubectl -n argo-cd patch app <app-name> --type merge -p '{"operation":{"sync":{"force":true}}}'

# Or delete and let ArgoCD recreate from git
kubectl -n argo-cd delete app <app-name>
# ArgoCD will re-create it from the parent all-cluster-services app
```


### Application stuck in "Running" operation (admission webhooks)

**Symptom:** An ArgoCD application shows a perpetual `Running` operation and
never reaches `Synced`, even though all resources are healthy.

**Cause:** Charts like `kube-prometheus-stack` and `ingress-nginx` include
admission webhook jobs with `helm.sh/hook-delete-policy: hook-succeeded`. The
job deletes itself before ArgoCD records completion, leaving the operation stuck.

**Fix:** Disable admission webhooks in the chart values:

```yaml
# In kubernetes-services/values.yaml (under the affected app)
admissionWebhooks:
  enabled: false
```

If the operation is already stuck, clear it manually:

```bash
kubectl patch app <app-name> -n argo-cd --type json \
  -p '[{"op": "remove", "path": "/operation"}]'
```

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

**Fix (nuclear — reset all Chrome state for one site):**

1. Navigate to the affected URL
2. Click the padlock/tune icon in the address bar → **Site settings**
3. Click **Clear data** to remove cookies, cache, and local storage for that
   origin
4. Reload the page

**Fix (Chrome profile reset — if the above doesn't help):**

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
This avoids polluting your browser cache with intermediate states.
:::

## Longhorn

### Cannot uninstall Longhorn

**Symptom:** `helm uninstall longhorn` hangs or fails.

**Cause:** Longhorn requires its uninstall job to detach all volumes and clean up
node state. Volumes still attached to running pods prevent uninstall.

**Fix:**

1. Scale down all workloads using Longhorn PVCs
2. Delete any remaining PVCs manually
3. Run the Longhorn uninstall procedure:

```bash
kubectl -n longhorn apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/uninstall/uninstall.yaml
kubectl -n longhorn get job/longhorn-uninstall -w
# Wait for completion, then
helm uninstall longhorn -n longhorn
```

### Volume degraded — replica rebuilding

**Symptom:** Longhorn UI shows a volume as `Degraded` with replicas rebuilding.

**Cause:** A node was restarted or lost network temporarily. Longhorn
automatically rebuilds under-replicated volumes.

**Action:** No action needed. Monitor progress in the Longhorn UI. Rebuilding
typically completes within minutes depending on volume size.

## Networking

### Ingress returning 404 or 503

**Symptom:** `https://<service>.<domain>` returns 404 Not Found or 503 Bad
Gateway.

**Checklist:**

1. **Service exists?** `kubectl get svc -n <namespace>`
2. **Endpoints populated?** `kubectl get endpoints -n <namespace> <svc-name>`
3. **Ingress resource correct?** `kubectl get ingress -n <namespace> -o yaml`
4. **TLS certificate ready?** `kubectl get cert -n <namespace>`
5. **DNS resolving?** `dig <service>.<domain>` — should return worker node IPs

### Certificate not issuing

**Symptom:** `kubectl get cert` shows `False` for Ready.

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
   `additions/cert-manager/templates/cloudflare-api-token-secret.yaml` must decrypt to a
   valid token with `Zone:DNS:Edit` permission.

## Cloudflare Tunnel

### Redirect loop through tunnel

**Symptom:** Browser shows `ERR_TOO_MANY_REDIRECTS` when accessing a
tunnelled service.

**Cause:** The tunnel service URL uses HTTPS, and ingress-nginx forces
an SSL redirect — creating an infinite loop.

**Fix:** Use `http://` (not `https://`) for the tunnel service URL in
the Cloudflare dashboard. The echo ingress has `ssl-redirect: false` as
a reference.

### WAF blocks access to SSH tunnel

**Symptom:** `cloudflared access login` returns
`failed to find Access application`.

**Fix:** Add a WAF skip rule for the SSH hostname. See
{doc}`/how-to/cloudflare-ssh-tunnel` Part 3 for details.

### Tunnel not connecting

**Symptom:** cloudflared pods are running but the Cloudflare dashboard shows
the tunnel as inactive.

**Checklist:**

1. **Tunnel token valid?** The SealedSecret must decrypt to a valid token:
   ```bash
   kubectl get secret cloudflared-credentials -n cloudflared -o jsonpath='{.data.TUNNEL_TOKEN}' | base64 -d | head -c 20
   ```
2. **Pods running?** `kubectl get pods -n cloudflared`
3. **Logs show errors?** `kubectl logs -n cloudflared deployment/cloudflared | tail -30`
4. **Outbound connectivity?** The pod needs to reach `*.cloudflareresearch.com` on port 7844.

### Connection refused for tunnelled service

**Symptom:** Cloudflare returns 502 Bad Gateway.

**Checklist:**

1. **Service URL correct?** The hostname in the tunnel config must match
   the Kubernetes service DNS name (e.g.
   `ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local`).
2. **Service port correct?** Use port 80 (not 443) for HTTP backends.
3. **Ingress resource exists?** Check the target namespace has an ingress
   for the hostname.

## NFS Mount Issues

### PVC stuck in Pending

**Symptom:** A PersistentVolumeClaim for LLM models stays in `Pending`.

**Checklist:**

1. **NFS server reachable?**
   ```bash
   kubectl run nfs-test --rm -it --image=busybox:1.37 -- ping -c 3 <nfs-ip>
   ```
2. **Export path correct?** Check `kubernetes-services/values.yaml` matches
   the NFS server's `/etc/exports`.
3. **PV exists and is Available?** `kubectl get pv`
4. **StorageClass mismatch?** NFS PVs in this project do not use a StorageClass
   — the PVC binds directly by name.

## K3s Control Plane

### API server unreachable

**Symptom:** `kubectl` commands fail with `connection refused` on port 6443.

**Checklist:**

1. **K3s service running?**
   ```bash
   ssh node01 sudo systemctl status k3s
   ```
2. **Certificates valid?** Check `/var/lib/rancher/k3s/server/tls/` on the
   control plane node.
3. **Disk full?** etcd can fail if the node runs out of disk space:
   ```bash
   ssh node01 df -h /
   ```

### etcd database too large

**Symptom:** K3s logs show `mvcc: database space exceeded`.

**Fix:** Compact and defragment etcd:

```bash
ssh node01
sudo k3s etcd-snapshot save --name manual-backup
sudo systemctl restart k3s
```

K3s's embedded etcd auto-compacts, but a restart forces immediate compaction.

## Supabase

### Postgres fails on NFS storage

**Symptom:** Supabase Postgres pod crashes with `chown` or permission errors.

**Cause:** NFS with `root_squash` prevents the Postgres container (UID 105,
GID 106) from changing file ownership. Unlike most Postgres images that use
UID/GID 999, the Supabase image uses non-standard IDs.

**Fix:** Use Longhorn (or another block storage provider) instead of NFS for
the Postgres PVC. See {doc}`/explanations/decisions/0006-longhorn-not-nfs`.

### Kong OOMKilled

**Symptom:** Supabase Kong pod restarts repeatedly with `OOMKilled`.

**Fix:** Set Kong memory limit to at least 2Gi. Lower values (512Mi–1Gi)
cause consistent OOM kills under normal load.

### Edge Function not updating after ConfigMap change

**Symptom:** Supabase Edge Function serves stale code after updating the
ConfigMap.

**Cause:** subPath ConfigMap mounts do not receive automatic updates from
Kubernetes. The pod must be restarted to pick up changes.

**Fix:** Delete the Edge Function pod to force a restart:

```bash
kubectl delete pod -n supabase -l app.kubernetes.io/name=supabase-functions
```

### Edge Function returns 404

**Symptom:** Requests to the Edge Function return 404 Not Found.

**Cause:** The Supabase Edge Runtime requires the `basePath` in the Hono
application to match the function directory name (the subPath mount point).

**Fix:** Ensure the `basePath` in the function code matches the directory name.
For example, if the function is mounted at `/open-brain-mcp`, the Hono app must
use `basePath: '/open-brain-mcp'`.

## Hardware

### RK1 module not detected in slot

**Symptom:** `tpi info` shows a slot as empty despite a module being seated.

**Fix:**
1. Power off the board
2. Reseat the compute module firmly
3. Power on and check again:

```bash
ssh root@turingpi
tpi info
```

### NPU not available for RKLlama

**Symptom:** RKLlama pod can't access `/dev/rknpu`.

**Checklist:**
1. Node must be an RK1 (not CM4) — NPU is only on RK3588
2. Pod must run privileged (already set in the DaemonSet)
3. Node must have label `node-type: rk1`:
   ```bash
   kubectl label node <node> node-type=rk1
   ```
