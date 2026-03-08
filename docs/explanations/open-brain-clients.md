# Open Brain Client Options

An analysis of client interfaces for Open Brain, covering file handling
constraints, architectural trade-offs, and potential directions.

## Current State

Open Brain stores thoughts (text + structured metadata) in Supabase PostgreSQL,
with MinIO providing S3-compatible object storage for file attachments. Three
server interfaces exist:

- **MCP server** (`brain.<domain>/mcp`) — OAuth 2.1 via GitHub, used by Claude.ai.
  Text-only capture (`capture_thought` accepts content + metadata, no file uploads).
  Can retrieve attachments via `get_attachment`.
- **Local stdio MCP server** (`open-brain-cli/`) — wraps REST and Storage APIs,
  used by Claude Code. Supports file upload/download directly over HTTP.
- **REST API** (`supabase-api.<domain>/functions/v1/open-brain-mcp`) — x-brain-key
  header auth, used by scripts and CLI tools

## Architecture

The system separates text capture from file uploads to avoid pushing binary data
through MCP context windows:

- **Text capture** — `capture_thought` on the public MCP server (Claude.ai) or
  via the REST API wrapper (local CLI). Claude.ai should summarise binary content
  as text before calling `capture_thought`.
- **File uploads** — always go directly to Supabase Storage API, never through
  the MCP context window. The local CLI and future Slack bot both use this path.
- **File retrieval** — `get_attachment` on the public MCP server downloads from
  MinIO via Supabase Storage and returns base64. Works for viewing individual
  attachments, not for bulk transfers.
- **Queries** — `search_thoughts`, `list_thoughts`, and `thought_stats` are
  available on both MCP servers.

## The File Upload Problem

MCP tool calls pass all data through the AI's context window. A typical
screenshot (1-3 MB) base64-encoded inflates to ~1.3-4 MB of text, which
exhausts Claude.ai's context in a single tool call. This is a fundamental
limitation of the MCP protocol as implemented by Claude.ai — there is no
side-channel for binary data.

**Approaches considered and rejected:**

| Approach | Why it fails |
|----------|-------------|
| Base64 in tool params | Fills context window on any non-trivial image |
| Chunked uploads | Chunks accumulate in conversation history — same problem |
| URL fetch from server | Only works for publicly-hosted files, not conversation uploads |
| Resize/thumbnail | Lossy; defeats the purpose of storing the original |

**What does work:**

- **File retrieval** via MCP is fine — `get_attachment` downloads from MinIO and
  returns base64. A 143 KB PNG takes ~20 seconds round trip (Claude.ai → MCP →
  Kong → Storage → MinIO → back). Functional but not fast.
- **Text capture** via MCP works perfectly — thoughts with structured metadata
  are small and well within context limits.

## Client Comparison

### Claude.ai (MCP)

**Pros:**
- Uses existing MAX subscription (no API costs)
- Rich AI reasoning for metadata extraction, search, and classification
- Project instructions customise behaviour
- OAuth 2.1 authentication (secure, no shared secrets)

**Cons:**
- Text-only capture — `capture_thought` does not accept file attachments
  (binary data would exhaust the context window). Claude.ai should summarise
  binary content as text before calling `capture_thought`.
- File retrieval is slow (~20s for a small image)
- No persistent state between conversations
- Conversation length limits can interrupt workflows

**Best for:** Text capture (including AI-summarised descriptions of binary
content), search, querying, analysis of existing thoughts.

### Claude Code (local stdio MCP server)

**Tested:** A local stdio MCP server (`open-brain-cli/`) wraps the REST and
Storage APIs. Claude Code connects via `.mcp.json` and gets 6 tools including
`upload_attachment` and `download_attachment` that handle files directly from
disk — no base64 through the context window.

**Pros:**
- File upload/download works — binary goes directly over HTTP, not through context
- File retrieval is fast — download to `/tmp`, Claude Code reads it (multimodal)
- Text capture and search work well via the REST API wrapper
- Uses MAX subscription (no API costs)
- Works remotely via Cloudflare tunnel (x-brain-key auth over HTTPS)

**Cons:**
- **File capture is clumsy** — pasted/dropped images in Claude Code are in-memory
  conversation data, not files on disk. To upload, the user must first save the
  file somewhere, then tell Claude Code the path. This defeats the goal of quick,
  frictionless capture.
- Claude Code can *see* images (multimodal) but cannot *save* them from the
  conversation to a file path — there is no tool for that.
- Retrieved images are described in text, not displayed visually (terminal limitation)

**Best for:** Text-only thought capture and search from a workstation. File
uploads are possible but too manual for a "quick capture" workflow.

**Verdict:** Good for querying and text capture, but not a replacement for
drag-and-drop file capture. The friction of "save file to disk first" makes
it unsuitable as the primary capture interface for images/PDFs.

### Slack Bot (direct API)

**Pros:**
- Native file upload handling — Slack receives files out-of-band, bot downloads
  via API, uploads directly to MinIO. No context window involvement.
- Mobile-friendly — capture from phone
- Thread-based conversations provide natural context
- Proven pattern — the predecessor project (2ndBrain) used this successfully
  with Gemini for AI classification and Obsidian for storage

**Cons:**
- Requires Claude API key for AI features (classification, metadata extraction),
  adding cost on top of MAX subscription. Without AI, it's just a dumb file uploader.
- Another service to deploy and maintain in the cluster
- Slack dependency (external service)
- Socket Mode needs a persistent WebSocket connection

**Best for:** File uploads (images, PDFs, screenshots), mobile capture,
quick notes on the go.

### Web UI (custom)

**Pros:**
- Full control over UX, drag-and-drop file upload
- Direct upload to Supabase Storage API (fast)
- Could use Supabase Auth for login

**Cons:**
- Significant development effort
- Yet another service to maintain
- Doesn't leverage AI for classification without API costs

**Best for:** Only if other options prove insufficient.

## The 2ndBrain Precedent

The predecessor project used Slack + Gemini + Obsidian:

1. User sends message/file to Slack DM
2. Slack bot downloads attachments, fetches thread context
3. Gemini Flash classifies intent and extracts metadata (two-call pattern)
4. Content filed into Obsidian vault with YAML frontmatter
5. Bot replies in-thread with confirmation

This worked well but required a Gemini API key (cost) and stored everything
in Obsidian (file-based, harder to query programmatically). Open Brain replaces
the storage layer with Supabase (structured, queryable) and MinIO (object
storage), but the client interface question remains open.

## Recommended Direction

Claude.ai is the primary client for both capture and retrieval. Text-only
capture covers the vast majority of use cases — Claude.ai's AI reasoning
extracts structured metadata before calling `capture_thought`, and
`get_attachment` handles file retrieval when needed.

1. **Claude.ai** — primary capture and retrieval interface. Text capture with
   rich AI metadata extraction, search, and analysis. File retrieval via
   `get_attachment`. Uses MAX subscription (no API costs).
2. **Claude Code** — workstation text capture and programmatic access. The
   local stdio MCP server (`open-brain-cli/`) provides fast search, text
   capture, and file upload/download for power-user workflows.
3. **Slack bot** — deferred. Would handle drag-and-drop file capture (images,
   PDFs, mobile screenshots) if text-only capture proves insufficient. The
   predecessor project (2ndBrain) proved the pattern works, but the added
   complexity (API costs, another service) is not justified until the pain
   of not having file capture is actually felt.

## Next Steps

- Continue using Claude.ai as the primary capture and retrieval client
- Use Claude Code local CLI for workstation-based workflows and file uploads
- Revisit Slack bot if file capture becomes a frequent pain point
- Phase 2b: embedding pipeline for semantic search (see ADR 0008)
