# Connect Claude.ai to Cluster Services via MCP

This guide explains how to connect [Claude.ai](https://claude.ai/) to an MCP
(Model Context Protocol) endpoint running in your cluster, giving Claude
persistent tool access to your self-hosted services.

The example here uses the Open Brain memory system ({doc}`open-brain`), but the
pattern applies to any MCP-compatible edge function exposed through your
Cloudflare tunnel.

## Prerequisites

- A working Cloudflare Tunnel with `cloudflared` deployed ({doc}`cloudflare-web-tunnel`).
- The MCP edge function deployed and responding (e.g. Open Brain step 5 onwards
  in {doc}`open-brain`).
- A Cloudflare Access **bypass** application for the API hostname so
  programmatic requests are not blocked by browser-based authentication
  (see "Bypass application for API endpoints" in {doc}`cloudflare-web-tunnel`).
- A [Claude.ai](https://claude.ai/) account with MCP integration access.

## Architecture

```
Claude.ai (cloud)
  │  HTTPS + x-brain-key header
  ▼
Cloudflare Edge (TLS termination, Access bypass for API hostname)
  │
  ▼
cloudflared pod (outbound tunnel)
  │  HTTP
  ▼
ingress-nginx → Kong → Supabase Edge Functions
  │
  ▼
MCP edge function (Deno) → Supabase database
```

Claude.ai calls the MCP endpoint as a remote tool server. The request flows
through the Cloudflare tunnel into the cluster, hits Kong (the Supabase API
gateway), and reaches the edge function. Authentication uses a shared secret
in the `x-brain-key` header — Cloudflare Access is bypassed for this hostname
so API clients are not prompted for browser-based login.

## 1 -- Verify the endpoint externally

Before configuring Claude.ai, confirm the endpoint is reachable from outside
your LAN:

```bash
# Should return {"error":"Unauthorized"} (no key provided)
curl -s https://supabase-api.<your-domain>/functions/v1/open-brain-mcp/health

# Should return {"status":"ok"}
curl -s -H "x-brain-key: <your-key>" \
  https://supabase-api.<your-domain>/functions/v1/open-brain-mcp/health
```

If the first command hangs or returns a Cloudflare error page, check:

- The tunnel route exists for `supabase-api.<your-domain>` in the Cloudflare
  dashboard.
- The Cloudflare Access bypass application is configured for this hostname.
- The ingress resource exists in the cluster
  (`kubectl get ingress -n supabase`).

## 2 -- Retrieve your MCP access key

Run this in your own terminal (not in a logged session):

```bash
kubectl get secret supabase-mcp-env -n supabase \
  -o jsonpath='{.data.MCP_ACCESS_KEY}' | base64 -d
```

:::{note}
If the decoded value ends with `#`, strip it — that is a comment marker from
the original secret file, not part of the key.
:::

## 3 -- Add the MCP connector in Claude.ai

1. Open [claude.ai](https://claude.ai/) and navigate to a **Project** (or
   create a new one).
2. Open **Project settings → Integrations**.
3. Click **Add integration** (or **Connect an MCP server**, depending on the
   current UI).
4. Enter:
   - **URL**: `https://supabase-api.<your-domain>/functions/v1/open-brain-mcp`
   - **Authentication header**: `x-brain-key: <your-key>`

:::{important}
Claude.ai's MCP integration expects servers that speak the
[MCP protocol](https://modelcontextprotocol.io/) (JSON-RPC over HTTP). If the
edge function is a plain REST API rather than an MCP protocol server, Claude.ai
may not discover the tools automatically. In that case you will need to wrap the
function in an MCP protocol adapter — see {ref}`mcp-protocol-compatibility`
below.
:::

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

(mcp-protocol-compatibility)=
## MCP protocol compatibility

Claude.ai's remote MCP integration uses the
[MCP protocol](https://modelcontextprotocol.io/) — specifically JSON-RPC
messages over HTTP with Server-Sent Events (SSE) for streaming.

If your edge function is a plain REST API (like the Open Brain example), it
will not speak this protocol natively. You have two options:

### Option A: Rewrite the function as an MCP server

Use the [MCP TypeScript SDK](https://github.com/modelcontextprotocol/typescript-sdk)
to implement the function as a proper MCP server. This is the cleanest
approach but requires rewriting the function.

### Option B: MCP-to-REST adapter

Add a thin adapter layer that translates MCP JSON-RPC calls into REST calls
to your existing API. This lets you keep the current REST function unchanged.

:::{note}
The MCP specification is evolving. Check the
[MCP docs](https://modelcontextprotocol.io/) for the latest transport
requirements when setting up your integration.
:::

## Troubleshooting

### "Unable to connect" in Claude.ai

- Verify the endpoint is reachable externally (step 1).
- Check that the Cloudflare Access bypass is active for the API hostname.
- Ensure the URL includes the full path
  (`/functions/v1/open-brain-mcp`), not just the domain.

### Tools not discovered

- Claude.ai expects MCP protocol (JSON-RPC), not a REST API. See
  {ref}`mcp-protocol-compatibility`.
- Check that the `/tools` endpoint returns valid tool definitions when called
  directly with curl.

### "Unauthorized" errors

- Confirm the `x-brain-key` header value matches the secret in the cluster.
- Check for trailing characters (`#`, newline) in the key.

### Timeout errors

- The Cloudflare tunnel adds latency. If the edge function is slow to start
  (cold start), the first request may time out.
- Check that the Supabase functions pod is running:
  `kubectl get pods -n supabase | grep functions`.

## See also

- {doc}`open-brain` — Deploy the Open Brain memory system
- {doc}`cloudflare-web-tunnel` — Expose services via Cloudflare Tunnel
- [MCP Protocol specification](https://modelcontextprotocol.io/)
