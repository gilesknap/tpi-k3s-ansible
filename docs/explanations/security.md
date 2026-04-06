# Security Model

This page describes the security measures in place across the cluster.

## Authentication and access control

### SSH access

- All nodes use **key-based SSH authentication** only (password auth is disabled).
- A dedicated `ansible` user is created on each node with passwordless sudo.
- The SSH keypair is stored in `pub_keys/ansible_rsa.pub` (public key only in Git).
- The private key lives on the operator's workstation and is mounted into the
  devcontainer via a Docker volume.

### Kubernetes RBAC

- The control plane uses the default K3s RBAC configuration.
- Headlamp has a dedicated `headlamp-admin` ServiceAccount bound to `cluster-admin`
  with a long-lived token Secret for dashboard access.
- ArgoCD has the `kubernetes` AppProject with `sourceRepos` restricted to the
  project's GitHub repo and trusted Helm chart registries.

### Service authentication

Authentication uses a three-layer model: Cloudflare Access (edge gate),
Dex OIDC or oauth2-proxy (ingress auth), and per-service RBAC. See
{doc}`authentication` for the full architecture with diagrams.

| Service | Layer 1 (Cloudflare) | Layer 2 (Ingress) | Layer 3 (App RBAC) |
|---------|---------------------|-------------------|-------------------|
| ArgoCD | LAN only (SSL passthrough) | Dex (native OIDC) | email → admin / readonly |
| argocd-monitor | Cloudflare Access | Dex (sidecar) | Inherits ArgoCD RBAC |
| Grafana | Cloudflare Access | Dex (`generic_oauth`) | email → Admin / Viewer |
| Open WebUI | Cloudflare Access | Dex (native OIDC) | email → admin / user |
| Headlamp | Cloudflare Access | oauth2-proxy | Token auth |
| Longhorn | Cloudflare Access | oauth2-proxy | None |
| Supabase Studio | Cloudflare Access | oauth2-proxy | Dashboard password |
| Echo | Cloudflare Access | None | None (public test) |
| RKLlama | — | None | Internal API (fronted by Open WebUI) |

See {doc}`/how-to/oauth-setup` for setup instructions.

## Secrets management

### Sealed Secrets

Sensitive values (API tokens, tunnel credentials, OAuth client secrets) are
encrypted using [Sealed Secrets](https://sealed-secrets.netlify.app/) and
stored in Git as `SealedSecret` resources. Only the cluster's sealed-secrets
controller can decrypt them.

Current SealedSecrets:

- `kubernetes-services/additions/cloudflared/tunnel-secret.yaml` — Cloudflare tunnel token
- `kubernetes-services/additions/cert-manager/templates/cloudflare-api-token-secret.yaml` — DNS API token
- `kubernetes-services/additions/argocd/argocd-dex-secret.yaml` — GitHub connector + all 5 Dex client secrets
- `kubernetes-services/additions/grafana/grafana-oauth-secret.yaml` — Grafana's Dex client secret
- `kubernetes-services/additions/open-webui/open-webui-oauth-secret.yaml` — Open WebUI's Dex client secret
- `kubernetes-services/additions/argocd-monitor/argocd-monitor-oauth-secret.yaml` — argocd-monitor Dex client + cookie secret
- `kubernetes-services/additions/oauth2-proxy/oauth2-proxy-secret.yaml` — GitHub OAuth App credentials + cookie secret

### Admin access

Admin email addresses are configured in `oauth2_emails` in
`kubernetes-services/values.yaml`. This single list drives admin role
assignment across Grafana, Open WebUI, and the oauth2-proxy email
allowlist. See {doc}`authentication` for details.

## Devcontainer credential isolation

The devcontainer is hardened to limit the blast radius of AI-assisted
development (Claude Code) and prompt injection attacks:

- **SSH agent forwarding is disabled** (`SSH_AUTH_SOCK=""`). A container-local
  agent is started instead; only the ansible key is unlocked manually after
  container start. Host GitHub SSH keys are never accessible.
- **Git credential helpers are blanked** on container creation. VS Code's
  auto-injected OAuth helper is overridden, so remote pushes require an
  explicit fine-grained PAT via `gh auth login`.
- **GitHub CLI credentials are per-repo**. A dedicated Docker volume
  (`gh-auth-<project>`) stores the PAT, scoped to only the repositories needed.
- **Claude Code is devcontainer-only**. A `UserPromptSubmit` hook blocks
  execution outside the container.
- **Network escape vectors require confirmation**. `ssh`, `scp`, `rsync`, and
  similar commands in Claude Code prompt for human approval.

See {doc}`/how-to/claude-code` for setup instructions.

## Pod Security Standards

Security contexts are applied at the workload level. See
{doc}`security-hardening` for a detailed breakdown of which workloads run
as non-root, which have read-only root filesystems, and which require
privileged access.

## Container image pinning

All container images are pinned to specific version tags. Renovate bot
monitors for updates and raises PRs automatically. See
{doc}`security-hardening` for the full policy.

## Network security

### Control plane taint

In multi-node clusters, the control plane node has a `NoSchedule` taint. No regular
workloads run on it — only K3s system components (CoreDNS, metrics-server, etcd,
kube-proxy). For single-node clusters the taint is skipped so all workloads can schedule.

### Cloudflare protection

Services exposed via the Cloudflare tunnel benefit from:

- **WAF** — Web Application Firewall with managed rulesets
- **DDoS protection** — automatic layer 3/4/7 mitigation
- **Bot management** — challenge suspicious traffic
- **Rate limiting** — configurable per-hostname rules

### No inbound firewall ports

The Cloudflare tunnel uses an **outbound-only** connection from the `cloudflared` pod.
No inbound ports need to be opened on your router for public-facing services.

### LAN isolation

ArgoCD uses SSL passthrough and is not routed through the Cloudflare
tunnel — it is accessible only from the LAN or via `kubectl port-forward`.
All other services are tunnel-exposed with Cloudflare Access email-gate
protection (except `supabase-api`, which uses a bypass policy for API
access authenticated by `x-brain-key`).

### NetworkPolicies

NetworkPolicies are not deployed by default. See {doc}`network-policies` for
the rationale and guidance on implementing them if needed.

## TLS everywhere

All ingress endpoints use TLS certificates from Let's Encrypt (production CA):

- Certificates are automatically issued and renewed by cert-manager
- DNS-01 validation via Cloudflare API (works for LAN-only services too)
- HSTS headers are set by ingress-nginx by default
- ArgoCD uses TLS passthrough (handles its own certificate)

## Recommendations

1. **Rotate SealedSecrets periodically** — re-seal with fresh values.
3. **Back up the sealed-secrets key** — without it, a cluster rebuild requires re-creating all secrets.
4. **Keep nodes updated** — `unattended-upgrades` handles security patches automatically.
5. **Monitor for alerts** — Prometheus Alertmanager captures security-relevant events.
6. **Review the production checklist** — see {doc}`/reference/production-checklist`.
