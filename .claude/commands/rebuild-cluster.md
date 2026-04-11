# Rebuild Cluster

Decommission and rebuild the K3s cluster from scratch, validating the
bootstrap path a new user would follow. NFS-backed data (LLM models,
Supabase DB backups) survives; **Longhorn PVC data is destroyed**.

## WARNING — DATA LOSS

This command **destroys all Longhorn-backed persistent data** including:
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
git push -u origin rebuild-$(date +%Y%m%d)
```

**Push the branch immediately** — ArgoCD's root app is configured with
`repo_branch` during Phase 3 and will fail to sync if the branch does
not exist on the remote (`unable to resolve '<branch>' to a commit SHA`).

#### If testing a PR branch

A common invocation is "rebuild on this branch to test PR #N". The PR
branch itself is the base branch for the rebuild:

1. Ask the user to `just switch-branch <pr-branch>` first so the live
   cluster is pointing at the PR state. (They should have a draft PR
   open already.)
2. Use the PR branch as `<base-branch>` in the commands above.
3. Note that this is a PR-testing rebuild — **Phase 8 has extra steps**
   (cherry-picking fixes and the reseal commit back onto the PR branch)
   so that merging the PR delivers both the code fix and the new sealed
   secrets in one go.

### 1b. Collect external credentials

Export the 8 external credentials that cannot be generated. Run this
while the cluster is still up:

```bash
just export-external-creds
```

This writes `.env` at the repo root (gitignored). Source it before
Phase 3:

```bash
set -a && source .env && set +a
```

Everything else (admin passwords, cookie secrets, Supabase JWTs, Dex
client secrets) is generated fresh.

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

## Phase 3: Rebuild (single playbook run)

With `GENERATE_SECRETS=true` and the external credential env vars from
Phase 1b, a single playbook run handles everything: K3s install, ArgoCD
setup, secret generation, sealing, git commit/push, and admin password.

```bash
GENERATE_SECRETS=true \
SSH_AUTH_SOCK="/tmp/ssh-agent.sock" \
ansible-playbook pb_all.yml --tags k3s,servers,cluster \
  --extra-vars repo_branch=<branch-name>
```

The playbook automatically:
1. Installs K3s on all nodes (labels GPU nodes with `nvidia.com/gpu.present`)
2. Configures NVIDIA container runtime on GPU nodes (`--tags servers`)
3. Deploys ArgoCD with full config (dex.config, RBAC, etc.)
4. Waits for the sealed-secrets controller (up to 300s)
5. Generates all secrets fresh (random tokens, Supabase JWTs, etc.)
6. Seals them with `kubeseal` using the new cluster's keys
7. Sets the admin password (generated or from `ADMIN_PASSWORD` env var)
8. Commits and pushes the sealed secret files
9. Applies the ArgoCD Dex sealed secret and labels it

The admin password is printed in the output and saved to
`/tmp/cluster-secrets/admin-password.txt`.

### Verify rebuild

```bash
kubectl get nodes  # 6 nodes Ready
kubectl get apps -n argo-cd  # 18 apps syncing
```

## Phase 4: Post-rebuild

### 4a. Force sync and verify secrets

```bash
just argocd-sync
```

Wait 60 seconds, then verify all 10 SealedSecrets show `True`:
```bash
kubectl get sealedsecrets -A --no-headers
```

If any show `False` with "no key could decrypt", ArgoCD hasn't synced
the new sealed secrets yet. Run `just argocd-sync` again.

### 4b. Restart Dex and secret-dependent pods

Dex and any pods that load secrets via `env.valueFrom.secretKeyRef` need
a restart to pick up the newly sealed secrets. Pods started before the
secrets were re-sealed will have stale values and OAuth will fail with
"invalid client credentials".

```bash
just restart-dex
kubectl rollout restart statefulset open-webui -n open-webui
```

### 4c. GPU node setup

No manual step needed. The `--tags servers` in Phase 3 installs the
NVIDIA container runtime before ArgoCD deploys the device-plugin
DaemonSet, and the DaemonSet's `nodeSelector` (`nvidia.com/gpu.present`)
ensures it only schedules on labelled GPU nodes. No CrashLoop cycle.

If GPU pods are still stuck (e.g. after a partial rebuild), run:
```bash
just gpu-setup
```

## Phase 5: Verify cluster health

**Do not proceed to browser testing until all checks below pass.**

### 5a. ArgoCD apps

Run `just status` repeatedly (with 60-second waits) until **all** of
these pass. Do not proceed until every app is Healthy:
- [ ] All nodes Ready
- [ ] **All 18** ArgoCD apps Synced/Healthy (including `nvidia-device-plugin` and `llamacpp` — if they are not Healthy, see Phase 4c)
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
- [ ] No failing pods (nvidia-device-plugin must be Running on ws03 — if CrashLooping, revisit Phase 4c)

If certificates are pending, restart cert-manager and wait 2 minutes:
```bash
kubectl rollout restart deployment cert-manager -n cert-manager
```

### 5c. Common issues

- **Monitoring pods stuck on ws03** — ws03 is tainted `workstation=true:NoSchedule`.
  Longhorn does NOT tolerate this taint, so no Longhorn storage is available on ws03.
  Pods needing PVCs should not schedule there. Monitoring components (Prometheus,
  Grafana, etc.) tolerate the taint but use Longhorn PVCs from other nodes.
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
- `headlamp`: HTTP 302 (oauth2-proxy redirect)
- `longhorn`, `supabase`, `argocd-monitor`: HTTP 302 (oauth2-proxy redirect)

All services must respond (no timeouts or 5xx errors).

## Phase 7: Verify via browser

Invoke **`/test-oauth-flow`** — that command contains the full browser
test matrix, cookie-clearing JavaScript, scroll-jacking workaround,
and failure-reporting procedure, and delegates the browser work to a
subagent to keep the main conversation context clean.

Do not proceed to Phase 8 until the subagent reports PASS for every
service. Any FAIL must be diagnosed before merge — check Dex secrets
(`argocd-dex-secret` keys match service-side secrets) and whether Dex
has been restarted since the last reseal.

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

### 8e. If this rebuild was testing a PR branch

Skip this subsection for fresh rebuilds. For PR-testing rebuilds, the
user wants one merge of **their PR** to deliver both the code fix *and*
the new sealed secrets — otherwise `main` keeps the old un-decryptable
ciphertexts and the cluster can't be safely pointed back at `main`
after merge.

1. **Cherry-pick any fix commits** made on the rebuild branch (bugs
   surfaced during rebuild) back onto the PR branch, then force-push
   the PR branch.
2. **Cherry-pick the playbook-generated `Re-seal all secrets for
   rebuilt cluster` commit** from the rebuild branch onto the PR
   branch as a separate commit. Force-push the PR branch.
3. **Do not** create a second PR from the rebuild branch — the PR
   that gets merged is the user's original PR, now carrying the
   reseal commit.
4. After the user merges their PR, they run
   `ansible-playbook pb_all.yml --tags cluster` (no `--extra-vars`)
   to switch ArgoCD tracking back to `main`, then delete the rebuild
   branch.

### 8f. Report

Tell the user:
- The cluster is rebuilt and all services are verified
- ArgoCD is tracking the **rebuild branch** (not main)
- For fresh rebuilds: the PR is ready for review
- For PR-testing rebuilds: any fix commits and the reseal commit have
  been cherry-picked onto their PR branch and force-pushed; their PR
  is ready to merge
- After merging, run this command to switch ArgoCD back to main:
  ```
  SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_all.yml --tags cluster
  ```
  (No `--extra-vars` needed — `group_vars/all.yml` already has `repo_branch: main`.)
- `/tmp/cluster-secrets/` has been deleted
- Any issues discovered and how they were fixed
