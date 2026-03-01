---
name: cloudflare
description: Cloudflare Tunnel and Access configuration — dashboard locations, service URL format, tunnel vs Access distinctions
---

# Cloudflare Tunnel & Access

## Dashboard Locations

- **Tunnels**: Main dashboard (dash.cloudflare.com) → Networking → Tunnels. NOT in Zero Trust.
- **Access Applications**: Zero Trust dashboard (one.dash.cloudflare.com).

## Tunnel Service URL Format

A single **Service URL** field with protocol prefix — no separate Type dropdown:
- `http://host` — plain HTTP
- `https://host:443` — HTTPS
- `ssh://host:22` — SSH

## Current Setup

- Wildcard Access policy: `*.gkcluster.org` (Custom input method)
- Tunnel routes: grafana, headlamp, open-webui, oauth2, argocd
- Longhorn is NOT exposed via tunnel
- `ssl_redirect` should be `false` when service is behind tunnel (tunnel terminates TLS)

## Reference Docs

- `docs/how-to/cloudflare-tunnel.md`
- `docs/how-to/cloudflare-web-tunnel.md`
