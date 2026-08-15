# gbrain vs OB1 — Comparison

Comparison of [garrytan/gbrain](https://github.com/garrytan/gbrain) and
[NateBJones-Projects/OB1](https://github.com/NateBJones-Projects/OB1) against
the requirements in [gbrain-integration.md](gbrain-integration.md).

## What the plan calls for

The integration plan describes a self-hosted personal knowledge management
system accessible via MCP, replacing the existing `open-brain-mcp` deployment.
Key requirements:

1. Persistent memory across all agent sessions (Claude Code, Desktop, Cursor)
2. MCP-first interface (HTTP MCP for remote access via Cloudflare Tunnel)
3. Hybrid retrieval (not vector-only)
4. Synthesis with citations and gap analysis
5. Markdown + git as source of truth (brain repo)
6. Self-wiring knowledge graph
7. PostgreSQL/pgvector backend (existing Supabase in-cluster)
8. Local embeddings via Ollama on nuc2 (nomic-embed-text, 768-dim)
9. OAuth 2.1 + PKCE for auth
10. ArgoCD GitOps deployment pattern
11. Dream cycle (background enrichment) — deferred but desired

## Head-to-head

| Criterion | gbrain | OB1 |
|---|---|---|
| **Hybrid retrieval** | Vector + BM25 + knowledge graph + RRF + reranking. Benchmarked at +31pp precision over vector-only | Vector-only (1536-dim cosine similarity via `match_thoughts()`). No BM25, no graph search |
| **Knowledge graph** | Self-wiring, deterministic (regex, no LLM calls), 8 relationship types, recursive CTE traversal | LLM-powered entity extraction (6 types, 6 relationships). Requires API calls to build graph |
| **Synthesis + citations** | 4-stage pipeline (Intent→Gather→Synthesize→Commit), structured citations with page+row, explicit gap analysis | No synthesis layer — returns raw search results. Clients do their own synthesis |
| **Brain repo (markdown + git)** | Core design — `.gbrain-source` maps repos to brains, `gbrain sync` materializes to DB, bidirectional export | No markdown/git backing. Data lives in PostgreSQL `thoughts` table only |
| **MCP tools** | ~47 operations auto-generated from contract. stdio + HTTP + OAuth 2.1 | 4-5 tools (search, capture, list, stats). HTTP + bearer token |
| **Dream cycle** | 11-phase autonomous maintenance (lint, backlinks, sync, synthesize, extract, embed, consolidate) | Entity extraction worker (async queue), but no autonomous maintenance cycle |
| **Ollama support** | First-class — curated models incl. nomic-embed-text 768d, configurable via `OLLAMA_BASE_URL` | Configurable LLM backend including Ollama, but embeddings default to OpenAI text-embedding-3-small (1536d) |
| **OAuth 2.1 + PKCE** | Built-in, works with Claude Code/Desktop/ChatGPT | Not present — uses `x-brain-key` header (static API key) |
| **Supabase compatibility** | Uses standard PostgreSQL — can connect to existing Supabase Postgres | Designed Supabase-first (Edge Functions, RLS, Auth). Self-hosted K8s path is community-contributed and bundles its own pgvector sidecar |
| **K8s deployment** | No Docker image or K8s manifests. Deploys as a binary + tunnel | Community K8s manifests exist (StatefulSet + pgvector sidecar). Tested on K3s v1.31 |
| **Maturity** | 7 weeks old, 18.7k stars, essentially solo (Garry Tan), v0.41, MIT license | 2.5 months old, 3.4k stars, 3 core contributors, no versioned releases, FSL-1.1-MIT |
| **Multi-agent concurrent R/W** | Supported — Minions queue + Postgres locking | Supported via Supabase RLS + concurrent MCP connections |
| **Import/capture** | Markdown files, git repos, meeting transcripts, voice (Twilio), iOS Shortcuts | 40+ import recipes (Gmail, Obsidian, ChatGPT exports, Slack, Discord, X/Twitter) |

## Alignment with the plan

**gbrain matches the plan almost exactly** — the plan was written for it. Every
numbered decision (hybrid retrieval, knowledge graph, brain repo, Ollama
embeddings, OAuth 2.1, dream cycle, Supabase backend) maps directly to gbrain
features.

**OB1 falls short on 6 of the 11 requirements:**

1. **No hybrid retrieval** — vector-only, the plan explicitly rejects this
2. **No synthesis/citations/gap analysis** — the plan calls this out as a key
   differentiator vs "raw chunk retrieval"
3. **No markdown+git backing** — the plan wants a brain repo that "survives
   cluster rebuilds" and "fits the existing GitOps ethos"
4. **No OAuth 2.1 + PKCE** — uses static API keys, incompatible with the plan's
   auth choice
5. **No dream cycle** — the plan defers this but wants the capability
6. **LLM-dependent graph construction** — the plan prefers gbrain's
   deterministic approach (less API cost, works offline)

**OB1's one advantage: existing K8s deployment path.** It has
community-contributed K3s manifests — gbrain has none. But wrapping gbrain in a
container is straightforward (it is a single Bun binary), and the integration
plan already specifies the Helm chart structure to build.

## Recommendation

**gbrain is the right choice for this plan.** The hybrid retrieval, self-wiring
graph, synthesis pipeline, markdown+git brain repo, and built-in OAuth 2.1 are
all load-bearing requirements that OB1 does not have.

The deployment gap (no K8s manifests) is the only area where OB1 does better,
and it is a one-time cost to containerize gbrain — the integration plan already
has the Helm chart structure specced out.

**OB1 would be a better fit** if the goal were simpler: "capture thoughts from
Slack/Discord and search them from Claude" with minimal setup. Its 40+ import
recipes and Supabase-native design make it easy to get running. But the
integration plan asks for something more ambitious — a hybrid-retrieval
knowledge brain with synthesis, citations, and a git-backed source of truth —
and that is gbrain's wheelhouse.
