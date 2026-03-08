# Open Brain Client Options

An analysis of client interfaces for Open Brain, covering file handling
constraints, architectural trade-offs, and potential directions.

## Current State

Open Brain stores thoughts (text + structured metadata) in Supabase PostgreSQL,
with MinIO providing S3-compatible object storage for file attachments. Two
server interfaces exist:

- **MCP server** (`brain.<domain>/mcp`) — OAuth 2.1 via GitHub, used by Claude.ai
- **REST API** (`supabase-api.<domain>/functions/v1/open-brain-mcp`) — x-brain-key
  header auth, used by scripts and CLI tools

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
- Cannot upload files (context window limit)
- File retrieval is slow (~20s for a small image)
- No persistent state between conversations
- Conversation length limits can interrupt workflows

**Best for:** Text capture, search, querying, analysis of existing thoughts.

### Claude Code (MCP and/or REST)

**Pros:**
- Could connect via the same MCP server (already deployed)
- Could also act as a REST client to the Supabase API directly
- Has filesystem access — could upload files by reading them locally
- Local execution avoids context window limits for file operations
- Primary workstation interface for development workflows

**Cons:**
- MCP support and capabilities in Claude Code are evolving
- REST client approach would need the x-brain-key configured locally
- Untested — needs experimentation to understand current capabilities

**Best for:** Workstation use, development-adjacent capture, file uploads
from local filesystem. Worth investigating as the primary interface.

**Open question:** Claude Code may be able to call MCP tools *and* make direct
HTTP requests to the REST API, giving it the best of both worlds — AI-powered
metadata extraction via MCP for text, direct HTTP uploads for files.

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

A hybrid approach, using each client for what it does best:

1. **Claude.ai / Claude Code** — primary interface for text capture, search,
   and retrieval. AI-powered metadata extraction included in MAX subscription.
2. **Slack bot** (lightweight, no AI) — file ingestion only. Receives files,
   uploads to MinIO, creates a thought with basic metadata (filename, type,
   timestamp). No API key needed — just a pipeline.
3. **Claude.ai / Claude Code** — enrich Slack-uploaded thoughts later. Search
   for recent unclassified thoughts, view the attachment, add proper metadata.

This avoids API costs while covering all capture scenarios. The Slack bot is
deliberately simple — a "file drop" rather than a full AI agent.

## Next Steps

- Test Claude Code as an MCP client and REST client for Open Brain
- Explore the Claude Code tab on claude.ai for potential unified experience
- Decide whether a lightweight Slack file-ingestion bot is worth building
- Consider whether the REST API (x-brain-key) needs updating to support
  the same attachment workflow
