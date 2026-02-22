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

### Stale `valuesObject` after branch switch

**Symptom:** ArgoCD child apps still track the old branch after switching
`targetRevision` in the root app.

**Cause:** A `valuesObject` field in the live Application CR overrides the
`repo_branch` from `values.yaml`.

**Fix:**

```bash
kubectl patch application all-cluster-services -n argo-cd --type json \
  -p '[{"op":"remove","path":"/spec/source/helm/valuesObject/repo_branch"}]'
```

See [](../how-to/work-in-branches.md) for full details.

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

**Symptom:** `https://<service>.gkcluster.org` returns 404 Not Found or 503 Bad
Gateway.

**Checklist:**

1. **Service exists?** `kubectl get svc -n <namespace>`
2. **Endpoints populated?** `kubectl get endpoints -n <namespace> <svc-name>`
3. **Ingress resource correct?** `kubectl get ingress -n <namespace> -o yaml`
4. **TLS certificate ready?** `kubectl get cert -n <namespace>`
5. **DNS resolving?** `dig <service>.gkcluster.org` — should return worker node IPs

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
   `additions/cert-manager/cloudflare-api-token-secret.yaml` must decrypt to a
   valid token with `Zone:DNS:Edit` permission.

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
