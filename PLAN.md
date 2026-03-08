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
  |           |
  |           v
  |      Longhorn (block storage)
  |
  +----> Supabase Storage API (via Kong)
              |
              v
         MinIO (S3-compatible object store)
              |
              v
         Longhorn (block storage)

Supabase Stack (k3s): Kong, PostgREST, Auth, Storage, MinIO, Studio
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
| MinIO | S3-compatible object store for file attachments | supabase |
| Longhorn PVCs | Postgres data + MinIO blobs (block storage) | supabase |

## MCP Tools (Remote Server)

1. **capture_thought** — store content + pre-extracted metadata (text-only)
2. **search_thoughts** — filter by topic, person, type, keyword
3. **list_thoughts** — recent items with filters
4. **thought_stats** — counts, distributions, top topics
5. **get_attachment** — retrieve a file from MinIO as base64

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

## Phase 2a — File Attachments (MinIO + Supabase Storage) ✓

*Completed. The design diverged from the original plan — see implementation
notes below.*

Replace Obsidian's image/PDF storage with in-cluster object storage.

### Why MinIO

Supabase Storage is already deployed (`deployment.storage.enabled: true`) but
needs an S3-compatible backend for blob persistence. MinIO is wired into the
Supabase Helm chart — enabling it gives us a production-ready object store
backed by Longhorn without adding external dependencies.

### Implementation Steps

1. **Enable MinIO in Supabase Helm values** ✓
   - Set `deployment.minio.enabled: true` in `kubernetes-services/templates/supabase.yaml`
   - Add Longhorn PVC for MinIO data (`storageClassName: longhorn`, 50Gi)
   - Add `nodeSelector: kubernetes.io/arch: amd64` (matches other Supabase pods)
   - Configure MinIO credentials in the existing `supabase-credentials` SealedSecret

2. **Create a storage bucket** ✓
   - Add SQL migration to create a `brain-attachments` bucket in
     `storage.buckets` (Supabase manages buckets in Postgres)
   - Set bucket policy: private (service_role access only)

3. **MCP server changes (`open-brain-mcp`)** ✓
   - `capture_thought` is **text-only** — no `attachments` parameter. Binary
     data through MCP tool calls exhausts Claude.ai's context window (a typical
     screenshot base64-encodes to 1-4 MB of text). Claude.ai summarises binary
     content as text before calling `capture_thought`.
   - `get_attachment` implemented — downloads a file from MinIO via Supabase
     Storage and returns base64 with MIME type. Works for viewing individual
     files in Claude.ai.
   - File uploads are handled outside the remote MCP server:
     - **Local CLI** (`open-brain-cli/`): `upload_attachment` sends files
       directly to Supabase Storage API over HTTP (no context window).
     - **Supabase Storage API**: direct HTTP uploads for scripts and future
       clients (e.g. Slack bot).
   - `list_thoughts` / `search_thoughts` include attachment info when present.

4. **Local CLI MCP server (`open-brain-cli/`)** ✓
   - Stdio-based MCP server for Claude Code, installed via `scripts/setup-brain-cli`.
   - Wraps the REST and Supabase Storage APIs using `x-brain-key` auth.
   - Six tools: `capture_thought`, `search_thoughts`, `list_thoughts`,
     `thought_stats`, `upload_attachment`, `download_attachment`.
   - File upload/download goes directly over HTTP — no base64 through the
     context window.

5. **Update Edge Function (optional)**
   - Not yet updated — REST API parity deferred

6. **Update documentation**
   - ADR 0011: MinIO for file attachments
   - Update `docs/how-to/open-brain.md` with attachment examples

### Design Notes

- Files are stored in MinIO (Longhorn PVC), metadata stays in Postgres
- The MCP server talks to Supabase Storage API (via Kong) rather than MinIO
  directly — this keeps auth consistent and uses Supabase's built-in file
  management (signed URLs, RLS policies, etc.)
- Base64 encoding in MCP tool params is the standard approach for Claude.ai
  tool calls that include binary data
- Bucket is private; signed URLs provide time-limited access for retrieval

## Phase 2b (deferred)

- Embedding pipeline: add OpenRouter API key, generate vector embeddings on capture
- Semantic search: `match_thoughts` function ready, needs embeddings populated
- ARM migration: move Supabase to ARM nodes if/when images support it
- Multi-arch container: add linux/arm64 build to open-brain-mcp CI
  (use native ARM runner to avoid slow QEMU emulation)

## Decision Records

See [docs/explanations/decisions/](docs/explanations/decisions/) for full ADRs.
