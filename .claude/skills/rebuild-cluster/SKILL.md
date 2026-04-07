---
name: rebuild-cluster
description: Tear down and rebuild the K3s cluster from scratch to validate documentation and commissioning. Destructive — all Longhorn data is lost.
user-invocable: true
---

# Rebuild Cluster

Decommission and rebuild the K3s cluster from scratch, validating the
bootstrap path a new user would follow. NFS-backed data (LLM models,
Supabase DB backups) survives; **Longhorn PVC data is destroyed**.

## WARNING — DATA LOSS

This skill **destroys all Longhorn-backed persistent data** including:
- Prometheus/Grafana metrics history
- Open WebUI chat history and uploads
- Supabase database (tables, storage objects, edge functions)
- Any other data on Longhorn volumes

NFS-backed data (LLM models, Supabase DB backups) is preserved.

**Ask the user to confirm they accept data loss before proceeding.**

## Important rules

- **Work autonomously** — commit and push freely to the rebuild branch.
  Do not ask for confirmation at each step; proceed through all phases.
- **Use `uv run`** for all git commits (pre-commit hooks need the uv venv).
- **Read CLAUDE.md** before starting — it has hard rules and foot-guns.
- All Ansible commands need `SSH_AUTH_SOCK="/tmp/ssh-agent.sock"`.
- Use `just status` throughout to check cluster health.

## Phase 1: Preparation

### 1a. Branch setup

```bash
git checkout main && git pull
git checkout -b rebuild-$(date +%Y%m%d)
```

### 1b. Extract secrets

Extract all plaintext secret values from the running cluster before
teardown. After rebuild, sealed-secrets generates new encryption keys
so existing SealedSecret YAML files become useless.

Extract these secrets and save to `/tmp/cluster-secrets/extracted-secrets.json`:

| Namespace | Secret | Purpose |
|-----------|--------|---------|
| argo-cd | argocd-dex-secret | GitHub OAuth, Dex client secrets |
| argocd-monitor | argocd-monitor-oauth | oauth2-proxy credentials |
| cert-manager | cloudflare-api-token | DNS-01 challenge |
| cloudflared | cloudflared-credentials | Tunnel token |
| monitoring | grafana-oauth-secret | Grafana OAuth |
| oauth2-proxy | oauth2-proxy-credentials | Shared proxy credentials |
| open-brain-mcp | open-brain-mcp-secret | Supabase + GitHub OAuth |
| open-webui | open-webui-oauth-secret | Open WebUI OAuth |
| supabase | supabase-credentials | All Supabase secrets (15 keys) |
| supabase | supabase-mcp-env | MCP access key |
| longhorn | admin-auth | Basic-auth password |
| monitoring | admin-auth | Basic-auth password |
| headlamp | admin-auth | Basic-auth password |
| argo-cd | argocd-secret | Admin password + server.secretkey |

Write a Python script that uses `kubectl get secret` and base64 decodes
all values into a JSON array. Also backup sealed-secrets encryption keys:
```bash
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > /tmp/cluster-secrets/sealed-secrets-keys.yaml
```

**Never commit `/tmp/cluster-secrets/` to git.**

### 1c. Check the admin-auth password

Read the `password` key from any `admin-auth` secret — you will need it
in Phase 5. Store it in a variable for later use.

## Phase 2: Decommission

Run the decommission playbook:

```bash
SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_decommission.yml
```

The playbook handles:
1. Stopping ArgoCD reconciliation (orphan cascade + finalizer stripping)
2. Scaling down Longhorn workloads and deleting PVCs
3. Stripping finalizers from Longhorn CRD resources
4. Uninstalling Longhorn and ArgoCD Helm releases
5. Deleting all app namespaces
6. Uninstalling k3s from all nodes (workers first, then control plane)
7. Cleaning up node state (iSCSI, /var/lib/longhorn, /var/lib/rancher)

### Monitoring the playbook

The playbook has retry loops for stuck resources. If a step takes longer
than expected, check for:
- **Longhorn volumes still attached** — strip finalizers from
  `volumeattachments.longhorn.io` and `volumes.longhorn.io`
- **Namespaces stuck in Terminating** — find remaining resources with
  `kubectl api-resources --verbs=list --namespaced -o name` and delete them
- **ArgoCD apps with finalizers** — patch finalizers to null

### Verify decommission

```bash
kubectl get nodes  # should fail — API server down
ssh ansible@<worker-node> "which k3s"  # should return nothing
ssh ansible@<worker-node> "ls /var/lib/rancher"  # should not exist
```

## Phase 3: Rebuild

```bash
SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_all.yml --tags k3s,cluster
```

The `--tags cluster` step will log an error on the Dex SealedSecret
apply (sealed-secrets CRD doesn't exist yet on a fresh cluster). This
is handled by `ignore_errors: true` and the secret is applied later by
ArgoCD once sealed-secrets syncs. See issue #247 for a proper fix.

### Verify rebuild

```bash
kubectl get nodes  # 6 nodes Ready
kubectl get apps -n argo-cd  # 18 apps syncing
```

## Phase 4: Bootstrap

### 4a. Wait for sealed-secrets

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=sealed-secrets \
  -n kube-system --timeout=300s
```

### 4b. Set admin password

Use the password extracted in Phase 1c:

```bash
just set-admin-password
```

### 4c. Re-seal all secrets

**ArgoCD Dex secret** — script the `seal-argocd-dex` recipe
non-interactively, reading the GitHub OAuth Client ID and Secret from
`extracted-secrets.json` (keys: `dex.github.clientID`,
`dex.github.clientSecret` in `argo-cd/argocd-dex-secret`). The recipe
also generates the argocd-monitor oauth2-proxy secret — both files are
created automatically.

**Open Brain MCP secret** — do NOT use `./scripts/seal-mcp-secret`
(it fetches Supabase credentials from the cluster, which doesn't exist
yet on a fresh rebuild). Instead use `just seal` with all 5 keys from
the extracted JSON.

**All other secrets** — use `just seal` for each, redirecting output to
the correct file path. Check existing paths with:
```bash
git ls-files -- '**/*secret*.yaml' | grep additions
```

For each remaining secret in the extracted JSON, run:
```bash
just seal <name> <namespace> key1=val1 key2=val2 ... \
  > kubernetes-services/additions/<service>/<name>-secret.yaml
```

**Key name reference** — the key names in the live secrets may differ
from the key names expected by the deployments. Always use these key
names when sealing (not the names from the extracted JSON):

| Secret | Seal with key name(s) |
|--------|----------------------|
| `cloudflare-api-token` | `api-token` |
| `cloudflared-credentials` | `TUNNEL_TOKEN` |
| `grafana-oauth-secret` | `CLIENT_SECRET` (uppercase — loaded via `envFromSecrets`) |
| `oauth2-proxy-credentials` | `client-secret`, `cookie-secret`, `client-id` |
| `open-webui-oauth-secret` | `client-secret` |
| `open-brain-mcp-secret` | `DATABASE_URL`, `MCP_JWT_SECRET`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `SUPABASE_SERVICE_KEY` |
| `supabase-credentials` | (15 keys — use all keys from extracted JSON as-is) |
| `supabase-mcp-env` | `MCP_ACCESS_KEY` (not `SUPABASE_ACCESS_TOKEN`) |

**File naming**: must be `*-secret.yaml` (singular) to match the
`.gitleaks.toml` allowlist.

### 4d. Switch ArgoCD to the rebuild branch

Edit `group_vars/all.yml`: set `repo_branch` to the rebuild branch name.
**Do not commit this change** — it is only needed temporarily so ArgoCD
syncs the re-sealed secrets from the branch. It is reverted in Phase 8a.

### 4e. Commit, push, and apply

```bash
uv run git add kubernetes-services/additions/
uv run git commit -m "Re-seal all secrets for rebuilt cluster"
git push origin <branch-name>
SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_all.yml --tags cluster
```

The `--tags cluster` run will:
- Compute the correct Dex client secret from `server.secretkey`
- Patch the ArgoCD ConfigMap with the resolved secret
- Label the `argocd-dex-secret` for `$secret:key` resolution
- Update the root Application to track the rebuild branch

### 4f. Force sync and verify secrets

```bash
just argocd-sync
```

Wait 60 seconds, then verify all 10 SealedSecrets show `True`:
```bash
kubectl get sealedsecrets -A --no-headers
```

If any show `False` with "no key could decrypt", ArgoCD hasn't synced
the new sealed secrets yet. Run `just argocd-sync` again.

### 4g. Restart Dex

```bash
just restart-dex
```

### 4h. Run `--tags servers` on GPU nodes

If the cluster has GPU nodes (e.g. ws03), the NVIDIA container toolkit
containerd config needs to be reapplied after k3s reinstall:

```bash
SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_all.yml --tags servers --limit ws03
```

### 4i. Create Prometheus admission webhook secret

The kube-prometheus-stack webhook TLS secret is not auto-created on
ArgoCD-managed installs (Helm hook job is pruned). Create it manually:

```bash
just create-prometheus-admission-secret
```

If the prometheus-operator pod is stuck in ContainerCreating, delete it
after creating the secret to trigger a restart.

## Phase 5: Verify via kubectl

Run `just status` and check:
- [ ] All nodes Ready
- [ ] All 18 ArgoCD apps Synced/Healthy
- [ ] No failing pods (nvidia-device-plugin CrashLoop on non-GPU nodes is OK temporarily)
- [ ] All certificates issued (`kubectl get certificates -A`)
- [ ] Cloudflare tunnel connected (`kubectl logs -n cloudflared -l app=cloudflared --tail=3`)

### Common issues

- **Monitoring pods stuck on ws03** — Longhorn CSI/engine-image may need
  time to deploy on ws03 after the toleration takes effect. Delete stuck
  pods to force reschedule after engine-image shows `deployed`.
- **Prometheus operator CrashLoop** — missing `grafana-prometheus-kube-pr-admission`
  secret. Create manually with a self-signed cert (keys: `cert`, `key`, `ca`).

## Phase 6: Verify via curl

Test all service URLs return HTTP 200:

```bash
for url in https://echo.gkcluster.org https://grafana.gkcluster.org \
           https://headlamp.gkcluster.org https://open-webui.gkcluster.org \
           https://longhorn.gkcluster.org https://argocd-monitor.gkcluster.org \
           https://supabase.gkcluster.org; do
  status=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 10 "$url")
  echo "$url -> HTTP $status"
done
```

Replace `gkcluster.org` with the actual `cluster_domain` from `group_vars/all.yml`.

## Phase 7: Verify via browser

Test that OAuth login works end-to-end in Chrome.

### 7a. Clear stale session cookies

The browser has cookies from the old cluster that won't be valid.
Clear cookies for `*.gkcluster.org` while keeping GitHub OAuth cookies
(on `github.com`) intact so the OAuth flow auto-approves.

1. Open a new tab and navigate to `https://echo.gkcluster.org`
2. Run JavaScript to clear cookies for the current domain:
   ```javascript
   document.cookie.split(';').forEach(c => {
     const name = c.split('=')[0].trim();
     document.cookie = name + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/';
     document.cookie = name + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=.gkcluster.org';
   });
   'cookies cleared'
   ```
3. Repeat for each service domain that needs OAuth testing:
   - `argocd.gkcluster.org`
   - `grafana.gkcluster.org`
   - `open-webui.gkcluster.org`
   - `argocd-monitor.gkcluster.org`

Note: HttpOnly cookies (set by oauth2-proxy, ArgoCD) cannot be cleared
via JavaScript. If OAuth login still uses stale sessions, inform the
user and ask them to manually clear cookies for `*.gkcluster.org` in
Chrome settings (Settings → Privacy → Clear browsing data → Cookies).

### 7b. Test OAuth login flow

Navigate to each service and verify the page loads after OAuth:

| URL | Expected |
|-----|----------|
| `https://argocd.gkcluster.org` | ArgoCD applications dashboard |
| `https://grafana.gkcluster.org` | Grafana home (logged in via Dex) |
| `https://open-webui.gkcluster.org` | Open WebUI chat interface |
| `https://argocd-monitor.gkcluster.org` | ArgoCD monitor page |

For each URL:
1. Navigate to the URL
2. The service should redirect to Dex → GitHub OAuth
3. GitHub auto-approves (cookies preserved) → redirect back
4. Verify the page content loads correctly
5. Take a screenshot or capture the page title as evidence

### 7c. Final state

Navigate to `https://argocd.gkcluster.org/applications` so the user
sees the ArgoCD applications dashboard when testing is complete.

## Phase 8: Prepare for merge

### 8a. Do NOT restore main tracking yet

**CRITICAL**: Do not switch `repo_branch` back to `main` before the PR
is merged. ArgoCD on `main` would sync the **old** sealed secrets,
which the new sealed-secrets controller cannot decrypt — causing all
apps with secrets to go Degraded.

Leave ArgoCD tracking the rebuild branch until after merge.

### 8b. Commit and push

Commit any remaining changes (doc fixes, foot-gun discoveries, etc.).
Push and verify the branch is clean.

### 8c. Create PR

Create a PR from the rebuild branch to `main`. Include:
- Summary of what was rebuilt and any fixes made
- Test results from Phases 5-7
- List of any documentation gaps discovered

**Do NOT merge the PR** — leave it for the user to review and merge
after they have tested the cluster manually.

### 8d. Clean up

```bash
rm -rf /tmp/cluster-secrets/
```

### 8e. Report

Tell the user:
- The cluster is rebuilt and all services are verified
- ArgoCD is tracking the **rebuild branch** (not main)
- The PR is ready for review
- After merging the PR, run these commands to switch ArgoCD back to main:
  ```
  # In group_vars/all.yml, verify repo_branch is set to "main"
  SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_all.yml --tags cluster
  ```
- `/tmp/cluster-secrets/` has been deleted
- Any issues discovered and how they were fixed
