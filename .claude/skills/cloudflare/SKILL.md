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
Services exposed via tunnel: grafana, headlamp, open-webui, oauth2-proxy, argocd, echo, supabase (Studio + API)

## Supabase Endpoints
- `supabase.gkcluster.org` — Studio UI (behind OAuth)
- `supabase-api.gkcluster.org` — Kong API gateway (x-brain-key auth, NOT behind OAuth)

## Gotchas
- Tunnel hostname config is managed in Cloudflare dashboard — NOT in this repo
- DNS resolution: nodes use local DNS (`192.168.1.1`), not Cloudflare DNS
  - ws03 had `systemd-resolved` overridden to `1.1.1.1` which broke `node01.lan` resolution
  - Fix: `sudo resolvectl dns enp5s0 192.168.1.1`
- Adding new services requires both: ingress in repo + tunnel hostname in Cloudflare dashboard

## Key Files
- `kubernetes-services/values.yaml` — cloudflared toggle and config
- `kubernetes-services/additions/ingress/` — ingress definitions for tunneled services
