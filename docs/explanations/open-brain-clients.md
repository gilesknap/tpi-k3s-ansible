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

A hybrid approach, using each client for what it does best:

1. **Slack bot** — primary capture interface. Handles text, images, PDFs, and
   quick notes with drag-and-drop ease. Slack's native file handling means
   binary data never touches a context window. Mobile-friendly for on-the-go
   capture. The predecessor project (2ndBrain) proved this pattern works well.
2. **Claude.ai** — search, query, and analysis of existing thoughts. Rich AI
   reasoning for exploring the knowledge base, finding connections, and
   generating summaries. Uses MAX subscription (no API costs).
3. **Claude Code** — workstation text capture and programmatic access. The
   local stdio MCP server provides fast search and text-only capture. File
   uploads are possible but too manual for casual use.

### The AI question for Slack

The Slack bot needs to decide whether to include AI for metadata extraction:

- **With AI (Claude API):** Automatic classification, topic extraction, and
  filing — like 2ndBrain did with Gemini. Costs money per token.
- **Without AI:** Dumb pipeline — saves files and raw text with basic metadata
  (timestamp, filename, source). Relies on Claude.ai / Claude Code to enrich
  thoughts later. No API cost.
- **Hybrid:** Use a small/cheap model (Haiku) for lightweight classification
  only. Keeps costs low while still providing useful auto-tagging.

## Next Steps

- Build a Slack bot for file and text capture into Open Brain
- Decide on AI integration level for the Slack bot
- Consider whether the Slack bot should reuse the 2ndBrain agent architecture
  or be a simpler purpose-built service
