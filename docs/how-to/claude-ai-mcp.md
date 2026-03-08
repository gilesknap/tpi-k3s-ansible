# Connect Claude.ai to Cluster Services via MCP

This guide explains how to connect [Claude.ai](https://claude.ai/) to the
Open Brain MCP server running in your cluster, giving Claude persistent tool
access to your self-hosted AI memory system.

The Open Brain MCP server speaks the
[MCP protocol](https://modelcontextprotocol.io/) (JSON-RPC over Streamable
HTTP) and authenticates via OAuth 2.1 using GitHub as the identity provider.

## Prerequisites

- A working Cloudflare Tunnel with `cloudflared` deployed ({doc}`cloudflare-web-tunnel`).
- The Open Brain stack deployed and healthy ({doc}`open-brain`).
- A **GitHub OAuth App** configured for the MCP server (created in step 2 below).
- A Cloudflare Access **bypass** application for the MCP hostname so the
  OAuth flow is not blocked by browser-based Cloudflare authentication
  (see "Bypass application for API endpoints" in {doc}`cloudflare-web-tunnel`).
- A [Claude.ai](https://claude.ai/) account with MCP integration access.

## Architecture

```
Claude.ai (cloud)
  |  OAuth 2.1 flow (GitHub identity)
  |  then: Authorization: Bearer <JWT>
  v
Cloudflare Edge (bypass Access app for brain.<your-domain>)
  v
cloudflared -> ingress-nginx
  v
open-brain-mcp pod (Python, port 8000)
  |-- OAuth endpoints (/authorize, /callback, /token)
  '-- /mcp -> MCP Streamable HTTP (JSON-RPC)
  v
PostgreSQL (Supabase DB, internal)
```

Claude.ai initiates an OAuth 2.1 authorization code flow against the MCP
server. The user authenticates with GitHub, the MCP server issues a JWT, and
subsequent MCP requests include the token in the `Authorization` header. The
MCP server connects directly to the Supabase PostgreSQL database for all
data operations.

## 1 -- Verify the health endpoint

Before configuring anything, confirm the MCP server is running and reachable
externally:

```bash
# Should return a 200 response with status info
curl -s https://brain.<your-domain>/health
```

If this hangs or returns a Cloudflare error page, check:

- The tunnel route exists for `brain.<your-domain>` in the Cloudflare
  dashboard.
- The Cloudflare Access bypass application is configured for this hostname.
- The ingress resource exists in the cluster
  (`kubectl get ingress -n supabase`).
- The MCP server pod is running: `kubectl get pods -n supabase -l app=open-brain-mcp`.

## 2 -- Create a GitHub OAuth App

1. Go to [GitHub Settings > Developer settings > OAuth Apps](https://github.com/settings/developers).
2. Click **New OAuth App**.
3. Fill in:
   - **Application name**: something descriptive (e.g. "Open Brain MCP")
   - **Homepage URL**: `https://brain.<your-domain>`
   - **Authorization callback URL**: `https://brain.<your-domain>/callback`
4. Click **Register application**.
5. Note the **Client ID** and generate a **Client secret**.

These values are stored in the MCP server's Kubernetes secret and referenced
by the deployment. If you have not yet created the sealed secret for the MCP
server, add `github-client-id` and `github-client-secret` to the secret
manifest alongside the other credentials.

## 3 -- Add the MCP connector in Claude.ai

1. Open [claude.ai](https://claude.ai/) and navigate to a **Project** (or
   create a new one).
2. Open **Project settings > Integrations**.
3. Click **Add integration** (or **Connect an MCP server**, depending on the
   current UI).
4. Enter the **URL**: `https://brain.<your-domain>/mcp`

Claude.ai will automatically initiate the OAuth flow — you will be redirected
to GitHub to authorize the application. No manual API key or header
configuration is needed.

## 4 -- Add project instructions

In the same project, add these **Project Instructions** so Claude knows when
and how to use the tools:

```
## Memory (Open Brain)

You have access to a persistent memory system via MCP tools.

### On capture
When the user shares something worth remembering (decisions, ideas, learnings,
meeting notes, tasks), extract metadata and call capture_thought:
- type: idea | decision | learning | question | reference | meeting | task
- topics: relevant topic tags
- people: people mentioned
- action_items: any action items identified
- source: conversation context

### On recall
When context from past conversations would help, use search_thoughts or
list_thoughts to find relevant memories before responding.

### On review
Use thought_stats to get an overview of stored memories when asked.
```

## 5 -- Test the integration

In a new conversation within the project:

1. Ask Claude to check its tools — it should list the Open Brain tools
   (`capture_thought`, `search_thoughts`, `list_thoughts`, `thought_stats`).
2. Ask Claude to run `thought_stats` — it should return a count (possibly zero
   if the database is empty).
3. Tell Claude something worth remembering and check that it calls
   `capture_thought`.

## Troubleshooting

### "Unable to connect" in Claude.ai

- Verify the health endpoint is reachable externally (step 1).
- Check that the Cloudflare Access bypass is active for `brain.<your-domain>`.
- Ensure the URL is `https://brain.<your-domain>/mcp` (not just the domain).

### OAuth flow fails or loops

- Confirm the GitHub OAuth App callback URL exactly matches
  `https://brain.<your-domain>/callback` (no trailing slash).
- Check the MCP server logs for OAuth errors:
  `kubectl logs -n supabase -l app=open-brain-mcp`.
- Verify the `github-client-id` and `github-client-secret` values in the
  Kubernetes secret match the GitHub OAuth App settings.

### Tools not discovered

- Confirm the MCP server is running and the `/mcp` endpoint responds.
- Check the MCP server logs for JSON-RPC errors.

### "Unauthorized" or 401 errors

- The JWT may have expired — disconnect and reconnect the integration in
  Claude.ai to trigger a fresh OAuth flow.
- Verify the MCP server can reach GitHub's API (for token exchange) from
  within the cluster.

### Timeout errors

- The Cloudflare tunnel adds latency. If the MCP server pod is restarting,
  the first request may time out.
- Check pod status: `kubectl get pods -n supabase -l app=open-brain-mcp`.

## See also

- {doc}`open-brain` — Deploy the Open Brain memory system
- {doc}`cloudflare-web-tunnel` — Expose services via Cloudflare Tunnel
- [MCP Protocol specification](https://modelcontextprotocol.io/)
