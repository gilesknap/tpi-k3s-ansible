# 3. Hybrid Intelligence Architecture

**Status:** Accepted

## Context

Nate's guide puts embedding generation and metadata extraction inside the MCP
server using OpenRouter API calls. However, we use Claude.ai as the primary
interface — it is already an LLM capable of understanding context.

## Decision

The MCP server is dumb CRUD. Claude.ai Project instructions direct Claude to
extract metadata (people, topics, action_items, type) from conversations before
calling `capture_thought` with structured content and metadata. Embedding
generation is deferred to Phase 2.

## Consequences

- No OpenRouter API key needed at launch
- Claude.ai does the thinking — better metadata quality (it has full context)
- MCP server is simpler to maintain and debug
- Semantic vector search unavailable until Phase 2 (metadata-only filtering)
- Metadata extraction quality depends on Claude.ai Project instructions
