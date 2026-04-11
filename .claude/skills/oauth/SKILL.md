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
  are read at startup. After rotating with `just seal-argocd-dex <subcommand>`,
  restart affected pods.
- **Dex secret needs ArgoCD label** — the `argocd-dex-secret` SealedSecret
  template must include `app.kubernetes.io/part-of: argocd` label. Without
  it, ArgoCD's `$secret:key` resolution in `dex.config` silently fails,
  passing literal key names as OAuth client IDs (→ GitHub 404).
- **Dex static client secrets must all be in argocd-dex-secret** —
  `dex.config` uses `$argocd-dex-secret:key` for each static client.
  Missing keys silently resolve to empty, causing "Failed to get token
  from provider" on login. The rebuild path (`scripts/seal-from-json`)
  seals all clients (grafana, open-webui, argocd-monitor) along with
  the matching service-side secrets in one pass.
- **Sidecar oauth2-proxy cookie clash** — the shared oauth2-proxy sets
  `cookie-domain=.gkcluster.org`, so its `_oauth2_proxy` cookie reaches all
  subdomains. Any service with its own oauth2-proxy sidecar (e.g.
  argocd-monitor) must use `--cookie-name=<unique>` to avoid validating
  the shared proxy's cookie with its own secret (→ infinite login loop).
- **oauth2-proxy `email_domains` must be `[]`** — the Helm chart defaults
  to `email_domains = ["*"]`, which allows any GitHub user through and
  **silently overrides** `authenticatedEmailsFile`. The fix is
  `config.configFile` with `email_domains = []`. This bug was found and
  fixed in PR #279 — do not remove the `configFile` override.
- **oauth2-proxy `cookie-secret` size** — must be exactly 16, 24, or 32
  bytes for the AES cipher. `base64.b64encode(token_bytes(32))` produces
  44 chars and crashes oauth2-proxy. Use `secrets.token_hex(16)` (32 hex
  chars = 32 bytes). This bug has regressed before — do not change the
  generation in `scripts/seal-argocd-dex`. See `/sealed-secrets` skill.
- **DEX duplicate `argo-cd` static client** — ArgoCD auto-generates an
  `argo-cd` DEX client (without `trustedPeers`). Our `dex.config` also
  declares one (with `trustedPeers: [argocd-monitor]`). DEX v2.45+ stores
  the first and drops the duplicate, so `trustedPeers` never takes
  effect. Fixed in PR #297 by adding `oidc.config` with
  `allowedAudiences: [argo-cd, argocd-monitor]`, which lets
  argocd-monitor authenticate as itself. The duplicate `argo-cd` client
  in `dex.config` is harmless but redundant — kept for clarity.
- **Dex/Grafana need restart after re-sealing** — pods that read secrets
  via `envFrom` or `secretKeyRef` cache values at startup. After
  `--tags cluster` or `just seal-argocd-dex`, run `just restart-dex` and
  `kubectl rollout restart sts grafana-prometheus -n monitoring`.
  Without this, Dex reports "invalid client_secret" even though the
  Secret objects match. See `/sealed-secrets` for the full namespace list.
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
