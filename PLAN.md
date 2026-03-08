# Open Brain — AI Memory for Claude

Self-hosted Supabase stack providing persistent AI memory accessible via MCP
(Model Context Protocol) from Claude.ai and other AI tools.

## Architecture

```
Claude.ai Project
  |  (extracts metadata, calls MCP tools)
  v
MCP Server (open-brain-mcp pod, port 8000)       REST clients
  |  OAuth 2.1 (GitHub identity)                   |  x-brain-key header
  |  MCP Streamable HTTP (JSON-RPC)                v
  |                                    Kong -> Edge Function (Deno)
  |                                                |
  +----> PostgreSQL (asyncpg, direct) <------------+
              |
              v
         Longhorn (block storage)

Supabase Stack (k3s): Kong, PostgREST, Auth, Storage, Studio
```

## Components

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| Supabase (Helm) | Full platform: db, auth, rest, functions, studio, kong | supabase |
| open-brain-mcp | Standalone MCP server (Python, OAuth 2.1 + PKCE via GitHub) | open-brain-mcp |
| Edge Function | REST API with 4 tools (capture, search, list, stats) | supabase |
| API Ingress | supabase-api.\<your-domain\> (x-brain-key auth, no OAuth) | supabase |
| MCP Ingress | brain.\<your-domain\> (OAuth 2.1 via GitHub) | open-brain-mcp |
| Studio Ingress | supabase.\<your-domain\> (behind OAuth2 proxy) | supabase |
| Longhorn PVC | Postgres data (block storage) | supabase |

## MCP Tools

1. **capture_thought** — store content + pre-extracted metadata
2. **search_thoughts** — filter by topic, person, type, keyword
3. **list_thoughts** — recent items with filters
4. **thought_stats** — counts, distributions, top topics

## Auth

- Studio: OAuth2 proxy (browser-based, GitHub login)
- MCP server: OAuth 2.1 with GitHub as identity provider (per-user JWTs)
- REST API: `x-brain-key` header with 64-char hex access key (shared secret)
- Database: Supabase service_role JWT (internal)

## ws03 Taint Strategy

ws03 is a workstation that may reboot. Taint `workstation=true:NoSchedule`
limits scheduling to intentional workloads:

- **Tolerates taint**: llamacpp (GPU), monitoring (grafana/prometheus)
- **Avoids ws03**: general workloads, Supabase, open-brain-mcp (scheduled on RK1/nuc2 nodes)
- **Status**: Taint applied; Supabase migrated to nuc2 (dedicated x86 worker)

## Phase 2 (deferred)

- Embedding pipeline: add OpenRouter API key, generate vector embeddings on capture
- Semantic search: `match_thoughts` function ready, needs embeddings populated
- ARM migration: move Supabase to ARM nodes if/when images support it
- Multi-arch container: add linux/arm64 build to open-brain-mcp CI
  (use native ARM runner to avoid slow QEMU emulation)

## Decision Records

See [docs/explanations/decisions/](docs/explanations/decisions/) for full ADRs.
