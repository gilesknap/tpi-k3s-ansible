# Plan: Migrate Cluster Auth to Native OIDC/OAuth

## Context

The cluster currently uses oauth2-proxy (GitHub OAuth) as a blanket auth gateway for all web services. We want to deploy argocd-ioc-monitor, which needs to talk to the ArgoCD API — but the token-paste UX is clunky. Rather than hack around it with a shared service account token, we're migrating services that support native OIDC/OAuth to use it directly. This gives argocd-monitor clean ArgoCD API integration and improves auth for other services too.

oauth2-proxy stays in place **only** for services without native auth (Longhorn, Supabase Studio).

## Services to Migrate

| Service | Auth Method | GitHub OAuth App |
|---------|------------|-----------------|
| ArgoCD | Built-in Dex -> GitHub connector | Dedicated app |
| argocd-monitor (new) | Proxies ArgoCD's Dex auth flow | Uses ArgoCD's Dex (no separate app) |
| Headlamp | Native OIDC (Helm `config.oidc`) | Shared or dedicated app |
| Grafana | Native GitHub OAuth (`auth.github`) | Shared or dedicated app |
| Open WebUI | Native OAuth (env vars) | Shared or dedicated app |

Services staying on oauth2-proxy: **Longhorn**, **Supabase Studio**

## Phase 1: ArgoCD OIDC via Dex + GitHub

**Goal**: Enable ArgoCD's built-in Dex with a GitHub OAuth connector so ArgoCD uses GitHub login natively.

### 1a. Create a GitHub OAuth App for ArgoCD
- **Manual step** (cannot be automated)
- Homepage URL: `https://argocd.{cluster_domain}`
- Callback URL: `https://argocd.{cluster_domain}/api/dex/callback`
- Note the Client ID and Client Secret

### 1b. Store credentials as a SealedSecret
- Create a Kubernetes secret with `dex.github.clientID` and `dex.github.clientSecret`
- Seal with `kubeseal`, save to `kubernetes-services/additions/argocd/argocd-dex-secret.yaml`
- File must match `*-secret.yaml` pattern for `.gitleaks.toml` allowlist

### 1c. Update `kubernetes-services/additions/argocd/argocd-cm.yml`
- Uncomment and configure the `oidc.config` / `dex.config` section
- Configure GitHub connector pointing to the sealed secret
- Set allowed orgs/teams or email restrictions if desired

### 1d. Create `kubernetes-services/additions/argocd/argocd-rbac-cm.yml`
- Define RBAC policies mapping GitHub users/groups to ArgoCD roles
- e.g., specific GitHub users -> `role:admin`, others -> `role:readonly`

### 1e. Update Ansible task `roles/cluster/tasks/argocd.yml`
- Add task to apply the new `argocd-rbac-cm` ConfigMap
- Ensure Dex secret is applied

### Files to modify:
- `kubernetes-services/additions/argocd/argocd-cm.yml`
- `kubernetes-services/additions/argocd/argocd-dex-secret.yaml` (new, sealed)
- `kubernetes-services/additions/argocd/argocd-rbac-cm.yml` (new)
- `roles/cluster/tasks/argocd.yml`

---

## Phase 2: Deploy argocd-monitor

**Goal**: Deploy argocd-monitor as an ArgoCD Application with Dex auth. The upstream argocd-monitor repo already has full Dex support in its Helm charts — this phase only needs to configure and deploy it.

### 2a. Create ArgoCD Application template
- `kubernetes-services/templates/argocd-monitor.yaml`
- Multi-source pattern: Helm chart from argocd-monitor repo + ingress sub-chart
- **No oauth2_proxy** on ingress — ArgoCD's Dex handles auth
- Namespace: `argocd-monitor`
- Helm values to configure:
  - `argocd.baseUrl`: internal ArgoCD service URL (`https://argocd-server.argo-cd.svc.cluster.local`)
  - Dex auth settings (callback URLs, cookie domain, etc.)

### 2b. Add chart repo to ArgoCD project
- Update `argo-cd/argo-project.yaml` sourceRepos to allow the argocd-monitor Helm chart source

### Files to create/modify:
- `kubernetes-services/templates/argocd-monitor.yaml` (new)
- `argo-cd/argo-project.yaml` (if sourceRepos update needed)

---

## Phase 3: Migrate Headlamp to Native OIDC

**Goal**: Configure Headlamp's built-in OIDC support, remove oauth2-proxy dependency.

### 3a. Create a GitHub OAuth App for Headlamp (or reuse a shared one)
- Callback URL: `https://headlamp.{cluster_domain}/oidc-callback`

### 3b. Store credentials as a SealedSecret
- `kubernetes-services/additions/dashboard/headlamp-oidc-secret.yaml`

### 3c. Update `kubernetes-services/templates/dashboard.yaml`
- Add Headlamp OIDC config to `valuesObject`:
  ```yaml
  config:
    oidc:
      clientID: <from-secret>
      clientSecret: <from-secret>
      issuerURL: https://github.com/login/oauth
      scopes: ["openid", "email", "profile"]
  ```
- Set `oauth2_proxy: false` on the ingress source

### Files to modify:
- `kubernetes-services/templates/dashboard.yaml`
- `kubernetes-services/additions/dashboard/headlamp-oidc-secret.yaml` (new, sealed)

---

## Phase 4: Migrate Grafana to Native GitHub OAuth

**Goal**: Configure Grafana's built-in GitHub OAuth, remove oauth2-proxy dependency.

### 4a. Create a GitHub OAuth App for Grafana (or reuse shared)
- Callback URL: `https://grafana.{cluster_domain}/login/github`

### 4b. Store credentials as a SealedSecret
- `kubernetes-services/additions/grafana/grafana-oauth-secret.yaml`

### 4c. Update `kubernetes-services/templates/grafana.yaml`
- Add `grafana.ini` OAuth config to `valuesObject`:
  ```yaml
  grafana:
    grafana.ini:
      auth.github:
        enabled: true
        client_id: <from-secret>
        client_secret: <from-secret>
        allowed_organizations: <optional>
        allow_sign_up: true
  ```
- Set `oauth2_proxy: false` on the ingress source

### Files to modify:
- `kubernetes-services/templates/grafana.yaml`
- `kubernetes-services/additions/grafana/grafana-oauth-secret.yaml` (new, sealed)

---

## Phase 5: Migrate Open WebUI to Native OAuth

**Goal**: Configure Open WebUI's built-in OAuth support.

### 5a. Create a GitHub OAuth App for Open WebUI
- Callback URL: `https://open-webui.{cluster_domain}/oauth/oidc/callback`

### 5b. Store credentials as a SealedSecret
- `kubernetes-services/additions/open-webui/open-webui-oauth-secret.yaml`

### 5c. Update `kubernetes-services/templates/open-webui.yaml`
- Add OAuth env vars to `valuesObject`:
  ```yaml
  extraEnvVars:
    - name: OAUTH_CLIENT_ID
      valueFrom: ...
    - name: OAUTH_CLIENT_SECRET
      valueFrom: ...
    - name: OPENID_PROVIDER_URL
      value: "https://github.com/login/oauth"
    - name: ENABLE_OAUTH_SIGNUP
      value: "true"
  ```
- Set `oauth2_proxy: false` on the ingress source

### Files to modify:
- `kubernetes-services/templates/open-webui.yaml`
- `kubernetes-services/additions/open-webui/open-webui-oauth-secret.yaml` (new, sealed)

---

## Phase 6: Clean Up oauth2-proxy Config

**Goal**: Reduce oauth2-proxy scope to only Longhorn + Supabase Studio.

- Verify Longhorn and Supabase Studio still work behind oauth2-proxy
- Update any documentation referencing the old auth setup
- Consider whether oauth2-proxy can be simplified (fewer upstream rules, etc.)

---

## Safety Considerations

### What agents MUST NOT do:
- **No `kubectl apply/patch/edit`** — ArgoCD self-heals. All changes go through git.
- **No commits to `main`** — all work in a feature branch.
- **No `kubeseal` execution** — requires cluster access and produces secrets that must be reviewed. This is a manual step.
- **No GitHub OAuth App creation** — must be done manually in GitHub UI.
- **No pushing to remote** without explicit approval.

### What agents CAN do:
- Create/edit files in the repo (templates, additions, values, ansible tasks)
- Read existing files for reference
- Run `ansible-lint` for validation
- Build documentation

### Rollback plan:
- All changes are in git on a branch — revert by not merging
- oauth2-proxy remains deployed and functional throughout — services can be switched back by setting `oauth2_proxy: true` on their ingress
- ArgoCD's Dex can be disabled by re-commenting the config and re-running the ansible playbook

---

## Verification

### Per-phase testing (after each phase is merged and deployed):
1. **ArgoCD OIDC**: Visit `argocd.{cluster_domain}`, verify GitHub login redirect via Dex, verify RBAC
2. **argocd-monitor**: Visit `argocd-monitor.{cluster_domain}`, verify no token dialog, verify app list loads, verify log streaming
3. **Headlamp**: Visit `headlamp.{cluster_domain}`, verify OIDC login, verify k8s dashboard works
4. **Grafana**: Visit `grafana.{cluster_domain}`, verify GitHub login, verify dashboards accessible
5. **Open WebUI**: Visit `open-webui.{cluster_domain}`, verify OAuth login, verify chat works
6. **Longhorn/Supabase**: Verify still accessible behind oauth2-proxy

### Smoke test for each service:
- `curl -s -o /dev/null -w "%{http_code}" https://<service>.{cluster_domain}/` should return 302 (redirect to login) when unauthenticated
