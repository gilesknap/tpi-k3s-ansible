# Open Brain — AI Memory for Claude

Self-hosted Supabase stack providing persistent AI memory accessible via MCP
(Model Context Protocol) from Claude.ai and other AI tools.

## Architecture

```
Claude.ai Project
  |  (extracts metadata, calls MCP tools)
  v
MCP Server (Supabase Edge Function)
  |  (dumb CRUD — no AI logic)
  v
Supabase Stack (k3s)
  - Kong API Gateway (port 8000)
  - PostgREST (REST API)
  - PostgreSQL + pgvector
  - Auth, Storage, Studio
  |
  v
Longhorn (block storage for Postgres)
```

## Components

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| Supabase (Helm) | Full platform: db, auth, rest, functions, studio, kong | supabase |
| MCP Function | Edge Function with 4 tools (capture, search, list, stats) | supabase |
| API Ingress | supabase-api.gkcluster.org (x-brain-key auth, no OAuth) | supabase |
| Studio Ingress | supabase.gkcluster.org (behind OAuth2 proxy) | supabase |
| Longhorn PVC | Postgres data (block storage) | supabase |

## MCP Tools

1. **capture_thought** — store content + pre-extracted metadata
2. **search_thoughts** — filter by topic, person, type, keyword
3. **list_thoughts** — recent items with filters
4. **thought_stats** — counts, distributions, top topics

## Auth

- Studio: OAuth2 proxy (browser-based, GitHub login)
- API: `x-brain-key` header with 64-char hex access key
- Database: Supabase service_role JWT (internal)

## ws03 Taint Strategy

ws03 is a workstation that may reboot. Taint `workstation=true:NoSchedule`
limits scheduling to intentional workloads:

- **Tolerates taint**: llamacpp (GPU), monitoring (grafana/prometheus), supabase
- **Avoids ws03**: general workloads (scheduled on RK1 nodes)
- **Status**: Code committed, taint NOT applied until nuc2 (second x86 node) is added

## Phase 2 (deferred)

- Embedding pipeline: add OpenRouter API key, generate vector embeddings on capture
- Semantic search: `match_thoughts` function ready, needs embeddings populated
- ARM migration: move Supabase to ARM nodes if/when images support it

## Decision Records

See [docs/explanations/decisions/](docs/explanations/decisions/) for full ADRs.
