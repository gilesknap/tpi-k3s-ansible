---
name: oauth
description: OAuth2-proxy authentication setup, configuration, and troubleshooting for the K3s cluster.
---

# OAuth / Authentication

## Architecture
- **Provider**: GitHub via oauth2-proxy (lightweight, ~128Mi vs ~2GB for Authentik/Keycloak)
- **Flow**: Cloudflare Access (wildcard `*.gkcluster.org`) → oauth2-proxy gateway → backend services
- **No native OIDC** — Cloudflare Access + oauth2-proxy only (branch `external-auth-n-z` was parked)

## Configuration
- oauth2-proxy enabled in `kubernetes-services/values.yaml`
- Reusable ingress sub-chart at `kubernetes-services/additions/ingress/` supports `oauth2_proxy` annotation mode
- Services behind OAuth get ingress annotations pointing to the oauth2-proxy auth endpoint

## Gotchas
- Chrome caching can cause stale redirects/blank pages after auth changes — fix with `chrome://settings/reset`
- SealedSecrets for oauth2-proxy credentials must match name+namespace exactly (encryption is bound)
- Merging into existing secrets requires `sealedsecrets.bitnami.com/managed: "true"` annotation on target

## Key Files
- `kubernetes-services/values.yaml` — oauth2-proxy toggle and config
- `kubernetes-services/additions/ingress/` — reusable ingress with auth modes
- `kubernetes-services/templates/` — ArgoCD Application CRDs
