# Security Review — tpi-k3s-ansible

**Date**: 2026-04-06
**Scope**: Full review of K3s Ansible + ArgoCD homelab across 6 domains

## Executive Summary

The project demonstrates strong fundamentals — zero hardcoded secrets,
SealedSecrets throughout, pre-commit gitleaks enforcement, and proper OIDC
integration. Several critical and high-severity issues were found, primarily
around overprivileged RBAC bindings, missing network segmentation, mutable
container image tags, and OAuth configuration gaps.

**Total findings: 8 CRITICAL, 13 HIGH, 19 MEDIUM, 14 LOW, 12 INFO**

---

## Top 5 Most Critical Findings

| # | Finding | File:Line | Impact |
|---|---------|-----------|--------|
| 1 | ~~Headlamp dashboard bound to `cluster-admin` ClusterRole~~ (downgraded — admin-only behind Cloudflare Access + oauth2-proxy + token login) | `additions/dashboard/rbac.yaml:14` | Acceptable risk for admin-only tool behind 3 auth layers |
| 2 | ArgoCD AppProject allows deployment to any namespace with all cluster-scoped resources | `argo-cd/argo-project.yaml:29-36` | Compromised app can create ClusterRoleBindings or deploy to kube-system |
| 3 | HTTP redirect_uri accepted for Open WebUI in Dex config | `additions/argocd/argocd-cm.yml:42` | Protocol downgrade — attacker intercepts auth codes in plaintext |
| 4 | No NetworkPolicy resources anywhere in the cluster | Repository-wide | No lateral movement barriers between pods |
| 5 | Container images use `:latest` mutable tag (open-brain-mcp) | `additions/open-brain-mcp/values.yaml:3`, `templates/open-brain-mcp.yaml:23` | Silent image replacement; supply chain attack vector |

---

## Quick Wins (High Impact, Easy Fixes)

| Fix | Effort | Files to Change |
|-----|--------|-----------------|
| Remove HTTP redirect_uri for Open WebUI | 1 line | `additions/argocd/argocd-cm.yml:42` |
| Set `tls_skip_verify_insecure: false` for Grafana | 1 line | `templates/grafana.yaml:58` |
| Add `cookie-httponly` + `cookie-samesite` to oauth2-proxy | 2 lines | `templates/oauth2-proxy.yaml` |
| Pin open-brain-mcp image to version tag | 2 lines | `additions/open-brain-mcp/values.yaml:3`, `templates/open-brain-mcp.yaml:23` |
| Add `| quote` filter to Ansible shell variables | 3 lines | `roles/k3s/tasks/worker.yml:53-54` |
| Remove echo test service or add auth | 1 template | `templates/echo.yaml` |

---

## 1. Secrets & Credential Management

| Severity | Finding | File:Line | Recommendation |
|----------|---------|-----------|----------------|
| MEDIUM | Gitleaks allowlist could be more specific | `.gitleaks.toml:9-11` | Document why plural `-secrets.yaml` is forbidden |
| POSITIVE | All 10 SealedSecret files use `encryptedData` (not plaintext) | All `*-secret.yaml` in `additions/` | No action needed |
| POSITIVE | Pre-commit gitleaks v8.28.0 enforces secret scanning | `.pre-commit-config.yaml:22-26` | Compliant |
| POSITIVE | All Python code reads secrets from env vars | `open-brain-mcp/`, `open-brain-cli/` | No hardcoded secrets found |
| POSITIVE | Seal scripts use secure practices | `scripts/seal-mcp-secret` | No shell history exposure |
| POSITIVE | `.gitignore` excludes `.env/`, `.venv/`, `venv/`, `env/` | `.gitignore:13-17` | Compliant |
| POSITIVE | No AWS/GCP/Azure credentials found | Full codebase scan | Clean |

**Verdict**: Strong secrets management. No critical issues.

---

## 2. Ansible & SSH Attack Surface

| Severity | Finding | File:Line | Recommendation |
|----------|---------|-----------|----------------|
| CRITICAL | Unquoted `K3S_TOKEN` env var in shell command — injection risk | `roles/k3s/tasks/worker.yml:53` | Use `{{ node_token.stdout \| quote }}` filter |
| CRITICAL | Unquoted `node_ip` and `flannel_iface` in shell command | `roles/k3s/tasks/worker.yml:54` | Apply `\| quote` filter to both variables |
| HIGH | `curl \| bash` pattern in devcontainer postCreate | `.devcontainer/postCreate.sh:13` | Download, verify, then execute separately |
| HIGH | Passwordless sudo (`NOPASSWD:ALL`) for ansible user | `pb_add_nodes.yml:51` | Restrict to specific command allowlist |
| MEDIUM | K3s install script downloaded without checksum verification | `roles/k3s/tasks/main.yml:23-27` | Add `checksum: sha256:<hash>` to `get_url` |
| MEDIUM | NVIDIA GPG key downloaded via curl without verification | `roles/update_packages/tasks/main.yml:75-79` | Use `get_url` with checksum parameter |
| MEDIUM | NVIDIA apt repo added via curl pipe to sed | `roles/update_packages/tasks/main.yml:83-88` | Use `apt_repository` module instead |
| MEDIUM | Unquoted `inventory_hostname` in `dig` command | `roles/known_hosts/tasks/main.yml:10` | Quote the variable |
| MEDIUM | Unquoted `inventory_hostname` in `ssh-keyscan` | `roles/known_hosts/tasks/main.yml:25` | Quote the variable |
| MEDIUM | Shell task for `INSTALL_K3S_EXEC` env var construction | `roles/k3s/tasks/worker.yml:49-55` | Use `command` module with `environment` dict |
| MEDIUM | Devcontainer Dockerfile uses unpinned yq (`/releases/latest/download/`) | `.devcontainer/Dockerfile:12-13` | Pin to specific version |
| LOW | Ansible user homedir created without umask control | `pb_add_nodes.yml:28-33` | Add `umask: "0077"` |
| LOW | `ansible.cfg` has commented `host_key_checking = False` | `ansible.cfg:76` | Currently secure — add comment to prevent re-enabling |
| INFO | RSA 3072-bit public key — adequate strength | `pub_keys/ansible_rsa.pub` | Consider annual rotation |
| INFO | All `get_url` tasks include `validate_certs: true` | `roles/tools/tasks/*.yml` | Compliant |

---

## 3. Kubernetes RBAC & Network Security

| Severity | Finding | File:Line | Recommendation |
|----------|---------|-----------|----------------|
| CRITICAL | Dashboard (Headlamp) has `cluster-admin` ClusterRoleBinding | `additions/dashboard/rbac.yaml:8-18` | Create minimal ClusterRole with only required permissions |
| CRITICAL | ArgoCD AppProject allows `namespace: "*"` and all cluster-scoped resources | `argo-cd/argo-project.yaml:29-36` | Restrict to specific namespaces; add `clusterResourceBlacklist` |
| CRITICAL | No NetworkPolicy resources detected across entire project | Repository-wide | Implement default-deny policies in application namespaces |
| HIGH | Grafana OAuth uses `tls_skip_verify_insecure: true` | `templates/grafana.yaml:58` | Set to `false`; use `tls_client_ca` for self-signed certs |
| HIGH | Supabase API ingress disables SSL redirect | `additions/supabase/templates/api-ingress.yaml:7` | Enable `ssl-redirect: "true"` or add conditional logic |
| HIGH | ArgoCD ingress has `ssl-redirect: false` | `argo-cd/ingress.yaml:7` | Set to `true` unless Cloudflare tunnel handles TLS termination |
| HIGH | ArgoCD admin role overly permissive (includes `delete/*`) | `additions/argocd/argocd-rbac-cm.yml:11-18` | Split into operational and emergency-only admin roles |
| MEDIUM | RKLlama DaemonSet uses `privileged: true` | `additions/rkllama/templates/daemonset.yaml:25,47` | Use device plugin + specific capabilities instead if possible |
| MEDIUM | Kernel-settings DaemonSet uses `hostNetwork`, `hostPID`, `privileged` | `templates/kernel-settings.yaml:17-18,29,54` | Move sysctl tuning to host boot phase; document as intentional |
| MEDIUM | open-brain-mcp Deployment lacks `securityContext` | `additions/open-brain-mcp/templates/deployment.yaml` | Add `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `drop: [ALL]` |
| MEDIUM | All 16 ArgoCD Apps use automated sync with `prune: true` + `selfHeal: true` | All templates in `templates/` | Consider manual sync for critical apps (databases, auth) |
| LOW | ArgoCD project doesn't deny `exec` into pods | `argo-cd/argo-project.yaml:12-18` | Add exec deny policy in RBAC |

---

## 4. Authentication & OAuth2 Security

| Severity | Finding | File:Line | Recommendation |
|----------|---------|-----------|----------------|
| CRITICAL | open-brain-mcp oauth.py accepts ANY `client_id` without validation | `open-brain-mcp/oauth.py:77-83` | Implement `ALLOWED_CLIENTS` allowlist |
| CRITICAL | HTTP `redirect_uri` accepted for Open WebUI in Dex config | `additions/argocd/argocd-cm.yml:40-42` | Remove the `http://` redirect URI on line 42 |
| HIGH | oauth2-proxy missing `cookie-httponly` and `cookie-samesite` flags | `templates/oauth2-proxy.yaml:33` | Add `cookie-httponly: "true"` and `cookie-samesite: "Strict"` |
| HIGH | Grafana OAuth `tls_skip_verify_insecure: true` | `templates/grafana.yaml:58` | Remove — enable TLS verification |
| HIGH | ArgoCD ingress lacks ingress-level auth annotations (defense-in-depth) | `argo-cd/ingress.yaml:1-24` | Add `auth-url`/`auth-signin` as additional layer |
| HIGH | Supabase API exposed without authentication | `additions/supabase/templates/api-ingress.yaml:1-24` | Add oauth2-proxy or verify Kong auth is sufficient |
| MEDIUM | open-brain-mcp `redirect_uri` not validated against allowlist | `open-brain-mcp/oauth.py:78,161,167` | Add redirect_uri validation before issuing redirects |
| MEDIUM | Unvalidated `X-Auth-Request-*` headers passed to backends | `additions/ingress/templates/ingress.yaml:20` | Document trust boundary; backends should re-validate |
| MEDIUM | Internal oauth2-proxy auth-url uses plaintext HTTP | `additions/ingress/templates/ingress.yaml:18` | Upgrade to HTTPS or document trust assumption |
| MEDIUM | PKCE not explicitly enforced at Dex level for all clients | `additions/argocd/argocd-cm.yml:20-48` | Add `public: true` markers; document PKCE enforcement |
| LOW | OAuth rate limiting absent on `/authorize`, `/callback`, `/token` | `open-brain-mcp/oauth.py` | Add application-level throttling or ingress `limit-rps` |
| LOW | State parameter passed through without format validation | `open-brain-mcp/oauth.py:166` | Add length/format check |
| INFO | Dex client secrets stored in SealedSecret | `additions/argocd/argocd-dex-secret.yaml` | Compliant |
| INFO | Email-based RBAC restricts admin access | `values.yaml:48-50` | Good practice |
| INFO | open-brain-mcp PKCE S256 implementation correct per RFC 7636 | `open-brain-mcp/oauth.py:189-194` | Compliant |
| INFO | Each service has its own Dex client (blast radius isolation) | `additions/argocd/argocd-cm.yml:33-48` | Good practice |

---

## 5. Supply Chain & Image Security

| Severity | Finding | File:Line | Recommendation |
|----------|---------|-----------|----------------|
| CRITICAL | open-brain-mcp uses `:latest` mutable tag | `additions/open-brain-mcp/values.yaml:3` | Pin to SHA256 digest |
| CRITICAL | `:latest` tag duplicated in ArgoCD Application manifest | `templates/open-brain-mcp.yaml:23` | Pin to specific version/digest |
| HIGH | RKLlama uses mutable `:main` branch tag with `imagePullPolicy: Always` | `additions/rkllama/templates/daemonset.yaml:37-38` | Pin to release tag + digest |
| HIGH | Python base image not fully pinned (`python:3.12-slim`) | `open-brain-mcp/Dockerfile:1` | Pin to `python:3.12.4-slim@sha256:...` |
| HIGH | Devcontainer base image not pinned to digest | `.devcontainer/Dockerfile:3` | Pin to SHA256 digest |
| MEDIUM | 7 GitHub Actions use major version tags instead of commit SHAs | `.github/workflows/docs.yml:15,18` and `.github/workflows/open-brain-mcp.yml:21,24,27,34,45,56` | Pin to full commit SHA |
| MEDIUM | CI pipeline publishes mutable `:latest` tag to registry | `.github/workflows/open-brain-mcp.yml:50` | Always push immutable digest alongside |
| LOW | `curl \| bash` in devcontainer and setup scripts | `.devcontainer/postCreate.sh:13`, `scripts/setup-brain-cli:12` | Download, verify hash, then execute |
| LOW | Unqualified registry references (busybox, nginx) | `additions/rkllama/templates/daemonset.yaml:22,80` | Use fully qualified `docker.io/library/...` |
| LOW | Cloudflared version tag only (no digest) | `additions/cloudflared/deployment.yaml:27` | Pin to `@sha256:...` |
| LOW | llamacpp uses beta/development tag (`b8172`) | `additions/llamacpp/templates/deployment.yaml:40` | Verify this is a stable release |

---

## 6. Network Exposure & Cloudflare Tunnel

| Severity | Finding | File:Line | Recommendation |
|----------|---------|-----------|----------------|
| HIGH | Supabase API exposed externally without authentication | `additions/supabase/templates/api-ingress.yaml:7` | Add auth layer or Cloudflare Access policy |
| HIGH | Headlamp dashboard exposed with cluster-admin privileges | `additions/dashboard/rbac.yaml:14` | Reduce RBAC scope |
| HIGH | Grafana TLS verification disabled for Dex endpoint | `templates/grafana.yaml:58` | Enable TLS verification |
| MEDIUM | No rate-limiting annotations on any Ingress | `additions/ingress/templates/ingress.yaml` | Add `nginx.ingress.kubernetes.io/limit-rps` |
| MEDIUM | Echo test service exposed without authentication | `templates/echo.yaml` | Decommission or add Cloudflare Access policy |
| MEDIUM | SSL redirect disabled globally when tunnel enabled | `additions/ingress/templates/ingress.yaml:11` | Document trust model; verify Cloudflare enforces HTTPS at edge |
| MEDIUM | Open WebUI OAuth scopes lack audience specification | `templates/open-webui.yaml:65` | Add audience parameter |
| LOW | Headlamp token is long-lived (no rotation) | `additions/dashboard/rbac.yaml:24-28` | Use TokenRequests API |
| LOW | No NetworkPolicies (intentional for homelab) | `docs/explanations/network-policies.md` | Document assumption |
| INFO | Tunnel routing managed in Cloudflare dashboard (not in repo) | N/A | Audit Cloudflare Access policies separately |
| INFO | cert-manager uses DNS-01 challenge (no public HTTP exposure) | `additions/cert-manager/templates/issuer-letsencrypt-prod.yaml:15-19` | Good practice |

### Services Exposed Externally (via Cloudflare Tunnel)

| Service | Auth Method | Risk Level |
|---------|-------------|------------|
| ArgoCD | Dex OIDC | Medium — no ingress-level pre-auth |
| Headlamp | oauth2-proxy | **High — cluster-admin RBAC** |
| Grafana | Dex OIDC | Medium — TLS verification disabled |
| Open WebUI | Dex OIDC | Medium — HTTP redirect_uri |
| Supabase Studio | oauth2-proxy | Low |
| **Supabase API** | **None** | **High — unauthenticated** |
| Open Brain MCP | oauth2-proxy | Medium — unvalidated client_id |
| RKLlama | Internal only | Low |
| Longhorn | oauth2-proxy | Low |
| ArgoCD Monitor | Dex OIDC + sidecar | Low |
| **Echo** | **None** | **Medium — test service** |
| oauth2-proxy | Self | Low |

---

## Access Control Architecture (Current State)

Services use two parallel auth paths:

| Service | Auth Layer | Admin Differentiation | Status |
|---------|------------|----------------------|--------|
| ArgoCD | Dex OIDC | Email → role:admin/readonly | Complete |
| argocd-monitor | Dex OIDC sidecar | Inherits ArgoCD RBAC | Complete |
| Grafana | Dex OIDC | Email → Admin/Viewer (JMESPath) | Complete |
| Open WebUI | Dex OIDC | Email → admin/user (env var) | Complete |
| Headlamp | oauth2-proxy (admin-only) | cluster-admin token | Admin-only (oauth2-proxy gate) |
| Longhorn | oauth2-proxy | None — binary gate | **Not differentiated** |
| Supabase Studio | oauth2-proxy | None — binary gate | **Not differentiated** |

Key architectural gap: oauth2-proxy's email allowlist (`oauth2_emails`) doubles
as both the "who can authenticate" list and the "who is admin" list. To add
read-only users, these must be decoupled.

---

## Architectural Recommendations

1. **Implement default-deny NetworkPolicies** — even in a homelab, lateral
   movement from a compromised pod (e.g. via a vulnerable LLM endpoint) is
   realistic. Start with deny-all in application namespaces and allowlist
   required flows.

2. **Replace cluster-admin dashboard binding** — create a read-only ClusterRole
   for Headlamp. If write operations are needed, scope them to specific
   namespaces and resource types.

3. **Restrict ArgoCD AppProject destinations** — replace `namespace: "*"` with
   an explicit list. Add `clusterResourceBlacklist` for sensitive types
   (ClusterRole, ClusterRoleBinding, Node).

4. **Pin all container images to SHA digests** — mutable tags (`:latest`,
   `:main`) are a supply chain risk. Automate updates via Renovate or
   Dependabot.

5. **Add ingress rate limiting globally** — a single
   `nginx.ingress.kubernetes.io/limit-rps` annotation in the shared ingress
   sub-chart template would protect all services.

6. **Audit Cloudflare Access policies** — tunnel routing is managed outside
   this repo. Verify every exposed service has a Cloudflare Access policy,
   especially Supabase API and Echo.

7. **Decouple admin emails from auth allowlist** — split `oauth2_emails` into
   `admin_emails` (admin access) and `allowed_emails` (all authenticated users)
   to support read-only users across services.

---

## CIS Kubernetes Benchmark Comparison

| CIS Control | Status | Notes |
|-------------|--------|-------|
| 5.1.1 — Minimize cluster-admin bindings | **FAIL** | Headlamp has cluster-admin |
| 5.1.3 — Minimize wildcard RBAC | **FAIL** | AppProject allows `*` namespace |
| 5.2.1 — Minimize privileged containers | **PARTIAL** | RKLlama, kernel-settings require privileged (hardware need) |
| 5.2.2 — Minimize hostNetwork/hostPID | **PARTIAL** | kernel-settings uses both (intentional for sysctl) |
| 5.3.2 — NetworkPolicy default deny | **FAIL** | No NetworkPolicies exist |
| 5.4.1 — Prefer secrets as files over env vars | **PARTIAL** | Mix of secretKeyRef and volume mounts |
| 5.7.1 — Avoid running as root | **PARTIAL** | open-brain-mcp lacks runAsNonRoot securityContext |
| 4.1.1 — Restrict API server access | **PASS** | No external API server exposure; ClusterIP only |
| 5.1.6 — Restrict automounting tokens | **PASS** | No default SA token mounting observed |
