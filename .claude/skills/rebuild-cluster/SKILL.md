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

If the user specifies a base branch (e.g. "rebuild from improve-rebuild-skill"),
use that instead of `main`:

```bash
git checkout <base-branch> && git pull
git checkout -b rebuild-$(date +%Y%m%d)
```

### 1b. Extract secrets

Extract all plaintext secret values from the running cluster before
teardown. After rebuild, sealed-secrets generates new encryption keys
so existing SealedSecret YAML files become useless.

```bash
just extract-secrets
```

This extracts all required secrets to `/tmp/cluster-secrets/extracted-secrets.json`
and backs up sealed-secrets encryption keys to `sealed-secrets-keys.yaml`.

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

The `--tags cluster` step automatically waits for the sealed-secrets
controller to be ready before applying the Dex SealedSecret (up to
300s). No manual wait is needed.

### Verify rebuild

```bash
kubectl get nodes  # 6 nodes Ready
kubectl get apps -n argo-cd  # 18 apps syncing
```

## Phase 4: Bootstrap

### 4a. Set admin password

```bash
export ADMIN_PASSWORD="<value from extracted-secrets.json>"
just set-admin-password
```

### 4b. Re-seal all secrets

**ArgoCD Dex secret** — set env vars from `extracted-secrets.json`
and run the recipe:

```bash
export GITHUB_CLIENT_ID=<dex.github.clientID from argo-cd/argocd-dex-secret>
export GITHUB_CLIENT_SECRET=<dex.github.clientSecret from argo-cd/argocd-dex-secret>
just seal-argocd-dex
```

**CRITICAL**: the `argocd-dex-secret` must contain keys for **every**
Dex static client defined in `dex.config` (`grafana.clientSecret`,
`open-webui.clientSecret`, `headlamp.clientSecret`,
`argocd-monitor.clientSecret`). If any are missing, Dex's
`$argocd-dex-secret:key` resolution silently returns empty and the
service gets "Failed to get token from provider" on login.

**All other secrets** — seal everything else in one command:

```bash
just seal-from-json /tmp/cluster-secrets/extracted-secrets.json
```

This handles cloudflare-api-token, cloudflared-credentials,
oauth2-proxy-credentials, open-brain-mcp-secret, supabase-credentials,
and supabase-mcp-env with the correct key names and output paths.

**Note**: do NOT use `./scripts/seal-mcp-secret` for open-brain-mcp —
it fetches Supabase credentials from the cluster, which doesn't exist
yet on a fresh rebuild. `seal-from-json` uses the extracted JSON instead.

### 4c. Commit, push, and apply

```bash
uv run git add kubernetes-services/additions/
uv run git commit -m "Re-seal all secrets for rebuilt cluster"
git push origin <branch-name>
SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_all.yml --tags cluster --extra-vars repo_branch=<branch-name>
```

The `--extra-vars` flag overrides `repo_branch` at runtime without
editing `group_vars/all.yml`, so there is nothing to revert afterwards.

The `--tags cluster` run will:
- Install/upgrade ArgoCD via Helm with all config (dex.config, RBAC, resource customizations) in a single step
- Label the `argocd-dex-secret` for `$secret:key` resolution
- Update the root Application to track the rebuild branch

### 4d. Force sync and verify secrets

```bash
just argocd-sync
```

Wait 60 seconds, then verify all 10 SealedSecrets show `True`:
```bash
kubectl get sealedsecrets -A --no-headers
```

If any show `False` with "no key could decrypt", ArgoCD hasn't synced
the new sealed secrets yet. Run `just argocd-sync` again.

### 4e. Restart Dex

```bash
just restart-dex
```

### 4f. GPU node setup

Restore NVIDIA container runtime config and restart GPU pods:

```bash
just gpu-setup
```

This auto-detects GPU nodes from inventory (`nvidia_gpu_node: true`),
runs `--tags servers` on them, then deletes the CrashLooping
nvidia-device-plugin pods so the DaemonSet creates fresh ones with
the NVIDIA runtime available. Also unblocks `llamacpp`.

## Phase 5: Verify cluster health

**Do not proceed to browser testing until all checks below pass.**

### 5a. ArgoCD apps

Run `just status` repeatedly (with 60-second waits) until **all** of
these pass. Do not proceed until every app is Healthy:
- [ ] All nodes Ready
- [ ] **All 18** ArgoCD apps Synced/Healthy (including `nvidia-device-plugin` and `llamacpp` — if they are not Healthy, see Phase 4f)
- [ ] All 10 SealedSecrets show `True` (`kubectl get sealedsecrets -A --no-headers`)

If any SealedSecrets show `False` with "no key could decrypt":
1. ArgoCD may have synced old sealed secrets from the wrong branch.
   Check `kubectl get app all-cluster-services -n argo-cd -o jsonpath='{.spec.source.targetRevision}'`.
   It must be the rebuild branch, NOT main.
2. Delete the failing SealedSecret and run `just argocd-sync`.
3. If the ArgoCD dex sealed secret is missing keys, re-run
   `ansible-playbook pb_all.yml --tags cluster --extra-vars repo_branch=<branch-name>`.

### 5b. Certificates and infrastructure

- [ ] All certificates issued (`kubectl get certificates -A` — all True)
- [ ] Cloudflare tunnel connected (`kubectl logs -n cloudflared -l app=cloudflared --tail=3`)
- [ ] No failing pods (nvidia-device-plugin must be Running on ws03 — if CrashLooping, revisit Phase 4h)

If certificates are pending, restart cert-manager and wait 2 minutes:
```bash
kubectl rollout restart deployment cert-manager -n cert-manager
```

### 5c. Common issues

- **Monitoring pods stuck on ws03** — Longhorn CSI/engine-image may need
  time to deploy on ws03 after the toleration takes effect. Delete stuck
  pods to force reschedule after engine-image shows `deployed`.
- **Prometheus operator CrashLoop** — the admission webhook secret is
  created automatically by `--tags cluster`. If it is still missing,
  run `just create-prometheus-admission-secret` then delete the stuck pod.
- **ArgoCD Monitor OAuth login loop** — if argocd-monitor loops back to
  Dex after "Grant Access", check the oauth2-proxy sidecar logs for
  "cookie signature not valid". The shared oauth2-proxy sets
  `cookie-domain=.gkcluster.org` so its `_oauth2_proxy` cookie reaches
  all subdomains. The sidecar must use `--cookie-name=_oauth2_proxy_monitor`
  to avoid the clash (already set in the template).

## Phase 6: Verify via curl

Read `cluster_domain` from `group_vars/all.yml`. Test all service URLs:

```bash
for url in https://echo.<domain> https://grafana.<domain> \
           https://headlamp.<domain> https://open-webui.<domain> \
           https://longhorn.<domain> https://argocd-monitor.<domain> \
           https://supabase.<domain> https://argocd.<domain>; do
  status=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 10 "$url")
  echo "$url -> HTTP $status"
done
```

Expected results:
- `echo`, `argocd`, `open-webui`: HTTP 200 (no auth or own login page)
- `grafana`: HTTP 302 (redirects to OAuth login)
- `longhorn`, `headlamp`, `supabase`, `argocd-monitor`: HTTP 302 (oauth2-proxy redirect)

All services must respond (no timeouts or 5xx errors).

## Phase 7: Verify via browser

**Delegate this entire phase to a subagent** using the Agent tool.
Browser verification generates large context (screenshots, long
Cloudflare redirect URLs, navigation retries) that bloats the main
conversation. Launch a single agent with `subagent_type: "general-purpose"`
and pass it:
- The cluster domain (from `group_vars/all.yml`)
- The full instructions below (7a–7f)
- The instruction to report back a summary table of PASS/FAIL per service

The subagent should not return until all services pass or failures
are clearly diagnosed.

---

Test OAuth login works end-to-end in Chrome for every service. The
browser has active GitHub sessions. Clicking "Grant Access" on Dex
and "Authorize" on GitHub is permitted — these only redirect back to
the cluster and do not modify any GitHub resources.

Read `cluster_domain` from `group_vars/all.yml` and use it throughout.

### 7a. Clear stale session cookies

After a rebuild, old cookies from the previous cluster will cause
issues. Clear them **immediately after navigating** to each service
domain — run this JavaScript on the page before interacting:

```javascript
document.cookie.split(';').forEach(c => {
  const name = c.split('=')[0].trim();
  document.cookie = name + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/';
  document.cookie = name + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=.<cluster_domain>';
});
```

Run this on each domain before testing login: `echo`, `argocd`,
`grafana`, `open-webui`, `argocd-monitor`, `longhorn`, `headlamp`,
`supabase`.

### 7b. Test order and login matrix

Test services in this order — the first Dex service establishes the
GitHub OAuth session, which subsequent services reuse:

**1. No-auth services (test first as a smoke test):**

| Service | Expected |
|---------|----------|
| Echo | Raw echo response (JSON with request headers) |
| ArgoCD | Applications dashboard (auto-logged-in from `--tags cluster` session) |

**2. First Dex OAuth service (establishes GitHub session):**

| Service | Login action | Logged-in indicator |
|---------|-------------|---------------------|
| Grafana | Click "Sign in with GitHub (via Dex)" | Page title contains "Home" or "Grafana" |

This will be the slowest flow — it goes through Dex → GitHub
authorize → Dex Grant Access → redirect back. Subsequent Dex
services reuse the GitHub session and auto-approve.

**3. Remaining native Dex OAuth services:**

| Service | Login action | Logged-in indicator |
|---------|-------------|---------------------|
| Open WebUI | See note below about scroll-jacking | Page title "Open WebUI" with chat interface |
| ArgoCD Monitor | Auto-redirects through sidecar oauth2-proxy → Dex | HTML contains "argocd-monitor" or health data |

**4. Services behind cluster oauth2-proxy (auto-redirect → GitHub):**

| Service | Logged-in indicator |
|---------|---------------------|
| Longhorn | Page title contains "Longhorn" |
| Headlamp | Page title contains "Headlamp" |
| Supabase | Page title contains "Supabase" |

### 7c. OAuth flow procedure

Use a single browser tab for all tests. For each service:

1. Navigate to `https://<service>.<cluster_domain>`
2. Run the cookie-clearing JavaScript from 7a
3. Reload the page and wait up to 10 seconds for redirects to settle
4. Check the current URL and page content:
   - **If on a Dex "Grant Access" page** → click the "Grant Access"
     submit button, then wait 5 seconds for redirect
   - **If on a GitHub authorize page** → click "Authorize" if a button
     is visible, otherwise wait 5 seconds (GitHub may auto-approve
     via existing cookies and redirect back automatically)
   - **If on the service login page** → click the OAuth/sign-in button,
     then repeat from step 4
   - **If on the service's authenticated page** → take a screenshot,
     record success
5. If the page shows an error (e.g. "Login failed", "Failed to get
   token from provider"), record the error — do NOT retry in a loop.
   Collect all failures and report them at the end.

### 7d. Known browser automation gotchas

- **Open WebUI scroll-jacking** — the login page has a parallax
  animation that hides the "Continue with GitHub" button off-screen.
  Normal scrolling won't reach it. Use JavaScript to click it:
  ```javascript
  document.querySelectorAll('button').forEach(b => {
    if (b.textContent.includes('GitHub')) b.click();
  });
  ```
- **Cloudflare Access redirect** — services behind Cloudflare Access
  (`headlamp`, `supabase`, `argocd-monitor`) redirect through
  `gilesk.cloudflareaccess.com` first. The browser's existing
  Cloudflare session typically auto-approves this.
- **ArgoCD is already logged in** — the `--tags cluster` playbook
  run creates an ArgoCD session, so it usually loads the applications
  dashboard directly without needing OAuth.

### 7e. Verification checklist

After testing all services, report a table:

```
| Service        | Status | Evidence                    |
|----------------|--------|-----------------------------|
| ArgoCD         | PASS   | Applications dashboard      |
| Grafana        | PASS   | Home page loaded            |
| Open WebUI     | PASS   | Chat interface              |
| ArgoCD Monitor | PASS   | Monitor page                |
| Longhorn       | PASS   | Dashboard loaded            |
| Headlamp       | PASS   | Cluster view                |
| Supabase       | PASS   | Studio dashboard            |
| Echo           | PASS   | Echo response               |
```

Any FAIL entries must include the error message. If OAuth failures
are found, check:
1. Does `argocd-dex-secret` contain the key for that service's
   Dex static client? (`kubectl get secret argocd-dex-secret -n argo-cd -o jsonpath='{.data}'`)
2. Does the service-side secret match? (e.g. `grafana-oauth-secret`
   `CLIENT_SECRET` must equal `argocd-dex-secret` `grafana.clientSecret`)
3. Has Dex been restarted since the secrets were updated?

### 7f. Final state

Navigate to `https://argocd.<cluster_domain>/applications` so the user
sees the ArgoCD applications dashboard when testing is complete.

## Phase 8: Prepare for merge

### 8a. Do NOT restore main tracking yet

**CRITICAL**: Do not run `--tags cluster` without `--extra-vars
repo_branch=<branch-name>` before the PR is merged. Pointing ArgoCD
back to `main` would sync the **old** sealed secrets, which the new
sealed-secrets controller cannot decrypt — causing all apps with
secrets to go Degraded.

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
- After merging the PR, run this command to switch ArgoCD back to main:
  ```
  SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_all.yml --tags cluster
  ```
  (No `--extra-vars` needed — `group_vars/all.yml` already has `repo_branch: main`.)
- `/tmp/cluster-secrets/` has been deleted
- Any issues discovered and how they were fixed
