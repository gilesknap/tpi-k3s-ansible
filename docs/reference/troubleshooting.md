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

## OAuth / Authentication

### Viewer emails can access oauth2-proxy-gated services

**Symptom:** Users with viewer emails can access admin-only services
(Headlamp, Alertmanager) — oauth2-proxy returns 202 instead of 403.

**Cause:** The oauth2-proxy Helm chart generates `email_domains = ["*"]` in
its default ConfigMap. This acts as an OR with `authenticatedEmailsFile` —
any email from any domain passes the domain check, so the restrictive email
file is silently ignored.

**Fix:** Set `email_domains = []` explicitly via `config.configFile` in the
Helm values so that only emails in the `authenticatedEmailsFile` (admin list)
are accepted. See `kubernetes-services/templates/oauth2-proxy.yaml`.

**Diagnosis:** Check the live ConfigMap:

```bash
kubectl get configmap oauth2-proxy -n oauth2-proxy -o yaml
# Look for: email_domains = ["*"]  ← this is the bug
```

Watch auth decisions in real time:

```bash
kubectl logs -n oauth2-proxy deploy/oauth2-proxy -f
# 202 = allowed, 401 = no session, 403 = denied
```

### oauth2-proxy returns 403 — CSRF cookie not found

**Symptom:** After GitHub authorisation, the oauth2-proxy callback returns
403 with "CSRF cookie not found" in the pod logs.

**Cause:** The tunnel route was changed (e.g. from direct-to-service to
through-ingress) while stale oauth2-proxy cookies remained in the browser.
The CSRF cookie set during `/oauth2/start` doesn't match the callback
context.

**Fix:** Clear all cookies for `*.gkcluster.org` (or use incognito) and
re-authenticate. If the problem persists, restart the oauth2-proxy pod:

```bash
kubectl rollout restart deployment/oauth2-proxy -n oauth2-proxy
```

### oauth2-proxy returns 403 — unauthorized (email not in allow list)

**Symptom:** oauth2-proxy logs show `AuthFailure: unauthorized` with an
email address.

**Cause:** The email is not in `authenticatedEmailsFile`. This can happen
after editing `admin_emails` in `kubernetes-services/values.yaml` without
restarting the oauth2-proxy pod (ArgoCD updates the config but doesn't
always trigger a pod restart).

**Fix:** Restart the oauth2-proxy pod after changing the email list:

```bash
kubectl rollout restart deployment/oauth2-proxy -n oauth2-proxy
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

## Local-nvme PVs and NFS backups

### Static PV not bound

**Symptom:** A pod stuck `Pending` with events like `no persistent volumes
available for this claim`.

**Check:** `kubectl get pv -l type=local-nvme` — every PV listed in
`additions/local-storage/` should be `Bound`.

**Fix:** Verify the data directory exists on the target node (the
`node`/`path` pair in its `k8s_data_dirs` entry, e.g.
`/var/lib/k8s-data/<app>`); re-run `ansible-playbook pb_all.yml --tags cluster` to let the
`k8s_data_dirs` role recreate any missing directory.

### Restoring from an NFS backup

The daily/weekly backup CronJobs in the `backups` namespace write
compressed dumps to `/bigdisk/k8s-cluster/backups/` on the NAS. To find
the latest, `ls -lt /bigdisk/k8s-cluster/backups/<app>/` on the
NAS host and pick the newest archive.

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

### New tunnel hostname won't resolve on LAN

**Symptom:** You add a new public hostname in the Cloudflare tunnel
dashboard, Cloudflare auto-creates the proxied CNAME, but LAN clients
keep getting `NXDOMAIN` for the new name. Public resolvers (`dig
@1.1.1.1`) return the record correctly.

**Cause:** Negative DNS caching. Before the record existed, your
router / `systemd-resolved` / browser queried the name, got
`NXDOMAIN`, and cached *that* result for its TTL. The cache doesn't
clear when Cloudflare publishes the new record — you have to flush it.

**Fix:** Flush the LAN-side caches in order of how hard they are to
reach:

```bash
# 1. Local browser — use incognito or clear browser DNS cache
#    (chrome://net-internals/#dns → "Clear host cache")

# 2. systemd-resolved on the client
sudo resolvectl flush-caches

# 3. The router's DNS cache — usually via Reboot or a "Flush DNS"
#    button in the admin UI. This is the one that tends to persist.
```

To confirm the negative cache is the cause, bypass the local resolver:

```bash
dig @1.1.1.1 new-hostname.example.com  # public resolver — should work
dig new-hostname.example.com           # local resolver — still NXDOMAIN
```

If only the local-resolver lookup fails, you are hitting cached
`NXDOMAIN`, not a Cloudflare problem.

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
