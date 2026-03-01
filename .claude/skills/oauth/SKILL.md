---
name: oauth
description: OAuth2 and authentication architecture — three-layer auth model, per-service auth details, email allowlists
---

# OAuth2 / Authentication Architecture

Three-layer auth: **Cloudflare Access** (perimeter) → **oauth2-proxy** (ingress gateway) → **native OIDC** (per-service RBAC).

## Per-Service Auth

| Service | oauth2-proxy | Native OIDC | Notes |
|---------|:---:|:---:|-------|
| Grafana | yes | generic_oauth (GitHub) | SSO + RBAC via native login |
| ArgoCD | yes | Dex + GitHub connector | `server.insecure: true` — nginx terminates TLS (ADR 0002) |
| Open WebUI | yes | trusted header (`X-Forwarded-Email`) | Header-based auto-login |
| Longhorn | yes | none | Gateway-only protection |
| Headlamp | yes | none (token login kept) | No proxy auth header support |
| RKLlama | no | none | Internal API consumed by Open WebUI |
| LlamaCpp | no | none | No ingress |

## Email Allowlists

All in `kubernetes-services/values.yaml`:
- `oauth2_emails` — oauth2-proxy gate (all external access)
- `argocd_admin_emails` — ArgoCD admin RBAC
- `grafana_admin_emails` — Grafana admin role

## Key Implementation Details

- oauth2-proxy auth-url must use **internal** `svc.cluster.local` address, not external hostname (breaks when traffic goes through tunnel).
- ArgoCD Dex OIDC config lives in `additions/argocd/argocd-cm.yml` (needs SealedSecret with GitHub OAuth creds).
- Grafana OAuth config lives in `additions/grafana/` (needs SealedSecret with GitHub OAuth creds).
- Ingress sub-chart toggle: `oauth2_proxy: true` in service's values to protect with oauth2-proxy.

## Reference Docs

- `docs/how-to/oauth-setup.md`
- `docs/how-to/unified-auth.md`
- `docs/explanations/decisions/` (ADRs)
