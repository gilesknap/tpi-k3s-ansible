# 4. Use x-brain-key Header Auth for MCP API

**Status:** Accepted

## Context

Existing cluster auth (GitHub OAuth via oauth2-proxy, Cloudflare Access) uses
browser-based redirect flows. MCP clients (Claude.ai, CLI tools) need
programmatic authentication without browser interaction.

## Decision

Use a custom `x-brain-key` HTTP header with a 64-character hex access key,
validated server-side in the Edge Function. The API ingress is NOT behind
oauth2-proxy.

## Consequences

- Simple auth that works with Claude.ai MCP connector
- Single shared key (not per-user) — acceptable for personal cluster
- Key rotation requires updating both the cluster secret and Claude.ai config
- API endpoint exposed without OAuth layer (Cloudflare Access still applies)
