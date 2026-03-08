# 10. MCP Protocol with GitHub OAuth for Claude.ai

**Status:** Accepted

**Supersedes:** [ADR 0004 — x-brain-key Header Auth](0004-mcp-auth-brain-key.md)

## Context

Claude.ai's custom MCP connector now requires the
[MCP protocol](https://modelcontextprotocol.io/) (JSON-RPC over Streamable
HTTP) and OAuth 2.1 authentication. The existing `x-brain-key` shared-secret
header auth (ADR 0004) cannot participate in Claude.ai's OAuth flow, so
Claude.ai can no longer connect to the Supabase Edge Function directly.

A standalone MCP server is needed that speaks the MCP wire protocol and
implements the OAuth 2.1 authorization code flow with PKCE (S256) that
Claude.ai initiates.

## Decision

Deploy a standalone Python MCP server (`open-brain-mcp`) as a Kubernetes
Deployment with its own Service and Ingress. The server uses GitHub as the
OAuth authorization server — GitHub identity provides per-user authentication
rather than a single shared key.

The existing Supabase Edge Function is retained for direct REST API access
(e.g. from scripts or CLI tools that still use `x-brain-key` auth).

Key design choices:

- **GitHub OAuth App** as the identity provider — reuses the same GitHub
  identity already used for cluster OAuth2 proxy and Cloudflare Access.
- **JWT session tokens** issued by the MCP server after OAuth callback,
  validated on every MCP request.
- **Separate pod** rather than sidecar or edge function rewrite — keeps the
  MCP protocol concerns isolated from the existing Supabase stack.
- **Direct database access** — the MCP server connects to the Supabase
  PostgreSQL database internally, bypassing Kong/PostgREST for lower latency.

## Consequences

- Claude.ai can connect via its native OAuth flow — no manual key copying
- Per-user GitHub identity replaces the single shared secret for MCP access
- Two auth mechanisms coexist: GitHub OAuth (MCP server) and x-brain-key
  (REST API) — adds surface area but serves different use cases
- The MCP server is an additional pod to maintain and monitor
- GitHub OAuth App must be created manually (Settings > Developer settings)
  with the correct callback URL
- Key rotation is simpler for MCP (OAuth tokens expire) but x-brain-key
  rotation for the REST API remains a manual process
