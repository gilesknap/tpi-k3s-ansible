# 8. Defer Embedding Pipeline to Phase 2

**Status:** Accepted

## Context

Vector embeddings require an external API (OpenRouter, OpenAI) to generate
1536-dimensional vectors. Claude.ai cannot generate embeddings directly.
The database schema and search function can be prepared now.

## Decision

Include `embedding vector(1536)` column (nullable) and `match_thoughts`
function in the initial schema. Do not wire up any embedding API at launch.
Phase 2 will add an API key to the cluster secret and server-side embedding
generation in the MCP function.

## Consequences

- Phase 1 uses metadata-only search (topic, person, type, keyword)
- Schema is ready for embeddings — no migration needed later
- No external API costs at launch
- Semantic search quality will improve significantly in Phase 2
