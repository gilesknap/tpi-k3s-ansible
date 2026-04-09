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
- **ArgoCD Dex audiences are hardcoded** — `server.additional.audiences` does
  nothing for Dex. Override the `argo-cd` client in `dex.config` with
  `trustedPeers` instead. See `additions/argocd/README.md`.
- **`oidc.config` disables Dex** — having `oidc.config` in argocd-cm causes
  `IsDexDisabled()=true`. Use `dex.config` only.
- **Re-sealing secrets requires pod restart** — pod env vars from `secretKeyRef`
  are read at startup. After `just seal-argocd-dex`, restart affected pods.
- **Dex secret needs ArgoCD label** — the `argocd-dex-secret` SealedSecret
  template must include `app.kubernetes.io/part-of: argocd` label. Without
  it, ArgoCD's `$secret:key` resolution in `dex.config` silently fails,
  passing literal key names as OAuth client IDs (→ GitHub 404).
- **Dex static client secrets must all be in argocd-dex-secret** —
  `dex.config` uses `$argocd-dex-secret:key` for each static client.
  Missing keys silently resolve to empty, causing "Failed to get token
  from provider" on login. The `just seal-argocd-dex` recipe generates
  secrets for all clients (grafana, open-webui, argocd-monitor) and
  also seals the matching service-side secrets.
- **Sidecar oauth2-proxy cookie clash** — the shared oauth2-proxy sets
  `cookie-domain=.gkcluster.org`, so its `_oauth2_proxy` cookie reaches all
  subdomains. Any service with its own oauth2-proxy sidecar (e.g.
  argocd-monitor) must use `--cookie-name=<unique>` to avoid validating
  the shared proxy's cookie with its own secret (→ infinite login loop).
- **oauth2-proxy cookie_secret size** — must be exactly 16, 24, or 32 bytes
  for AES cipher. Using `base64.b64encode(token_bytes(32))` produces 44
  chars → crash. Use `secrets.token_urlsafe(32)[:32]` instead.
- **Ingress auth-url must be cluster-internal** — the ingress sub-chart's
  `auth-url` uses the internal service (`oauth2-proxy.oauth2-proxy.svc`).
  Using the external domain resolves via Cloudflare to IPv6, which is
  unreachable from the cluster, causing intermittent 500s on all
  oauth2-protected ingresses.
- **Dex base URL redirects** — `/api/dex` 301s to `/api/dex/` which returns
  404. OIDC clients that don't follow redirects (e.g. Open WebUI's authlib)
  need the full discovery URL: `.well-known/openid-configuration`.
- **Grafana 12.x requires `[users].allow_sign_up`** — the per-provider
  `allow_sign_up` under `[auth.generic_oauth]` is not sufficient alone.
  Also set `[auth].disable_signup_form: true` to block manual signup.
## Key Files
- `kubernetes-services/values.yaml` — oauth2-proxy toggle and config
- `kubernetes-services/additions/ingress/` — reusable ingress with auth modes
- `kubernetes-services/templates/` — ArgoCD Application CRDs
