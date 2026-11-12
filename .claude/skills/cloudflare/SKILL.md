---
name: cloudflare
description: Cloudflare Tunnel and Access configuration for exposing K3s services externally.
---

# Cloudflare

## Architecture
- **Cloudflare Tunnel**: runs as a pod in the cluster, exposes services externally
- **Cloudflare Access**: wildcard policy on `*.gkcluster.org` — all subdomains protected
- **Flow**: Internet → Cloudflare edge → Tunnel pod → NGINX Ingress → Service

## Exposed Services
The tunnelled hostnames are the `tunnel_services` list in
`cloudflare/locals.tf` (grafana, headlamp, oauth2, argocd-monitor, home,
argocd, alertmanager, minecraft, scrap, pages, ntfy, ...): read it there
rather than trusting a copy.
- `ntfy.<domain>` has an Access **Bypass** app (the phone app cannot do
  the Access login) and the zone's one Free-plan rate-limiting rule
  (path-based: Free cannot match the hostname), both in `cloudflare/`;
  ntfy's own token auth is the gate (docs/how-to/ntfy.md)
- `mc.<domain>` (Minecraft game port) is deliberately NOT a tunnel route — it is a
  DNS-only A record on the VPS relay's public IP (`additions/vps-relay/`)

## Gotchas
- **Edge config is code in `cloudflare/` (OpenTofu)**: tunnel routes, DNS,
  Access apps and policies, zone settings, cache and rate-limiting rules (login methods are
  dashboard-only)
  (docs/how-to/cloudflare-as-code.md). Change it there, `just cf-plan`
  (read-only token) and the owner runs `just cf-apply`; a dashboard edit
  is drift that the next apply reverts. Live per-account values (IDs,
  emails) are in the gitignored `cloudflare/live.auto.tfvars`; state is
  local, encrypted, gitignored. Never run `cf-apply` / `tofu apply` yourself.
- **Tunnel token is tofu-managed**: `random_bytes.tunnel_secret` in
  `cloudflare/tunnel.tf`, output `tunnel_token`. Rotate: bump
  `tunnel_secret_rotation`, owner runs `just cf-apply`, then
  `just cf-seal-tunnel-token` (seals it, updates `.env`'s
  `CLOUDFLARE_TUNNEL_TOKEN` if present, never prints it), PR/merge, wait
  for sync, `kubectl -n cloudflared rollout restart deployment/cloudflared`,
  then `just cf-tunnel-disconnect` (old connections survive a rotation)
  and check only the pods' connector IDs reconnect. Never rotate in the
  dashboard: tofu doesn't read the secret back, so it would reseal a dead
  one. The first `cf-apply` on an imported tunnel rotates it. Run `cf-`
  recipes from the main checkout (docs/how-to/cloudflare-as-code.md)
- DNS resolution: nodes use local DNS (`192.168.1.1`), not Cloudflare DNS
  - a node with `systemd-resolved` overridden to `1.1.1.1` cannot resolve `<node>.lan` names
  - Fix: `sudo resolvectl dns enp5s0 192.168.1.1`
- Adding new services requires both: ingress in repo + an entry in
  `tunnel_services` in `cloudflare/locals.tf` (route + DNS), then plan/apply
- **Cloudflare tunnel sends `http://` redirect_uri** — services behind the
  tunnel with `ssl_redirect: false` generate `http://` OAuth callbacks. Dex
  static clients must list both `http://` and `https://` redirect URIs.
- **Tunnel routes must go through the ingress** — route all tunnel hostnames
  to `http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local`.
  Direct-to-service routes (e.g. `http://home.home.svc.cluster.local`) bypass
  the ingress controller and oauth2-proxy entirely, so auth headers like
  `X-Auth-Request-Email` will be empty. Cloudflare Access still authenticates,
  but oauth2-proxy features (email headers, sign-out) won't work.
- **Cloudflare Access login methods** — GitHub (the Owner policy requires
  it) or one-time PIN (Viewers). An Access prompt is Cloudflare's; a second
  GitHub prompt after it comes from Dex or oauth2-proxy inside the cluster.
- **MCP / non-browser clients** — they cannot complete the Access login.
  Use a service-token (`non_identity`) policy, as scrap's `/mcp` does in
  `cloudflare/access.tf`. Only if the host is truly public, set
  `access_bypass = true` on its `tunnel_services` entry and add a bypass
  app in `access.tf`; `cloudflare/access_guard.tf` fails the plan for a
  bypass app on a hostname not marked that way. Access apps are code: the
  most specific destination wins over the `*.gkcluster.org` wildcard, so
  there is no dashboard ordering to check.

## Key Files
- `cloudflare/` — OpenTofu edge config (tunnel, DNS, Access, WAF)
- `kubernetes-services/additions/cloudflared/` — cloudflared Deployment and tunnel-secret
- `kubernetes-services/values.yaml` — `enable_cloudflare_tunnel` toggle
- `kubernetes-services/additions/ingress/` — ingress definitions for tunneled services
