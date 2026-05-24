# gbrain Integration Plan

## Context

This document captures decisions made in a planning session. The goal is to deploy
[garrytan/gbrain](https://github.com/garrytan/gbrain) as a self-hosted personal
knowledge management (PKM) system, accessible via MCP from any Claude session or
other AI agent.

**Key repos:**
- Cluster config: `gilesknap/tpi-k3s-ansible`
- gbrain: `garrytan/gbrain` (18.6k stars, TypeScript, Bun)

---

## What gbrain is

A self-wiring knowledge graph + hybrid RAG engine that acts as persistent memory
across all agent sessions. Key properties:

- **Markdown + git** as source of truth (brain repo) — Obsidian-compatible mental model
- **Hybrid retrieval**: pgvector HNSW + BM25 + knowledge graph, not vector-only
- **Synthesis with citations and gap analysis** — not raw chunk retrieval
- **MCP-first**: 30+ tools over HTTP MCP, works with Claude Code, Claude Desktop,
  Cursor, and any other MCP client
- **Multi-agent**: multiple agents can read/write concurrently

---

## Decisions made

### 1. Purpose
General-purpose personal PKM — not cluster-specific. All projects, all contexts.
Any agent can contribute or query.

### 2. Replace open-brain-mcp
Replace the existing `open-brain-mcp` deployment entirely. No data migration from
the existing `thoughts` table — clean start.

### 3. Brain repo
A new **private GitHub repo** as the brain repo (markdown files, git-backed).
Survives cluster rebuilds. Fits the existing GitOps ethos.

Brain repo auth: **GitHub PAT** sealed as a SealedSecret and mounted into the
gbrain pod. PATs are already used routinely with agents — familiar and
straightforward.

### 4. Authentication — two layers

**Layer 1: Cloudflare Access with service tokens (network-level).**
Cloudflare Access policy on `brain.{{ cluster_domain }}` requires a valid service
token. Requests without valid `CF-Access-Client-Id` / `CF-Access-Client-Secret`
headers are rejected at the edge — unauthenticated traffic never reaches gbrain.

MCP clients (Claude Code, Claude Desktop, Cursor) send the service token
credentials as custom HTTP headers in their config:

```json
{
  "mcpServers": {
    "gbrain": {
      "type": "http",
      "url": "https://brain.example.com/mcp",
      "headers": {
        "CF-Access-Client-Id": "${GBRAIN_CF_CLIENT_ID}",
        "CF-Access-Client-Secret": "${GBRAIN_CF_CLIENT_SECRET}"
      }
    }
  }
}
```

**Layer 2: gbrain's built-in OAuth 2.1 + PKCE (application-level).**
gbrain is its own identity provider — it manages clients and tokens internally
(no external IdP like GitHub/Google). Clients are registered via CLI
(`gbrain auth register-client`) or the admin dashboard. This provides
defence in depth: even if Cloudflare Access were bypassed, gbrain's OAuth
protects the data.

**Limitation:** claude.ai MCP integrations cannot send custom headers, so
they cannot pass the Cloudflare Access service token. claude.ai access is
deferred to a future revisit — current target clients are Claude Code,
Claude Desktop, and Cursor, all of which support custom headers.

### 5. Embeddings
**ollama on nuc2, CPU-only, `nomic-embed-text` model (768-dim).**

Reasoning:
- RK1 NPU (rkllama) is flaky — avoided entirely; ollama uses ARM64/x86 CPU BLAS
- Workstation GPU (ws03) is a gaming machine — NoSchedule taint, do not use
- nuc2 is x86_64 with AVX2, fast CPU BLAS, no GPU contention
- nomic-embed-text is ~137MB, minimal resource footprint
- No external API dependency, no billing

Ollama pod: pin to `nuc2`, CPU-only (set `CUDA_VISIBLE_DEVICES=""`),
`nomic-embed-text` pulled on startup.

**Dimension compatibility:** gbrain's default schema uses 1536-dim vectors.
nomic-embed-text produces 768-dim vectors. Verify that gbrain supports
configurable vector dimensions before deploying. If not, select an
alternative model that produces 1536-dim output, or check whether gbrain
adapts its schema to the configured embedding provider.

**Embedding configuration:** gbrain auto-detects providers by API key, and
supports OpenAI-compatible endpoints (like ollama) via custom base URL. This
is configured through `gbrain config set` or `~/.gbrain/config.json`, not
just environment variables.

**Note:** ollama replaces the existing standalone llamacpp deployment. llamacpp
uses llama.cpp directly; ollama wraps llama.cpp with model management and an
API server. No reason to keep both — ollama is strictly more capable. When
better GPU hardware is available, move the ollama deployment to that node and
enable GPU passthrough.

### 6. Database
**Existing Supabase** (already deployed in the cluster, pgvector enabled). gbrain
runs its own migrations into a new schema — no conflict with the existing `thoughts`
table.

**Connection method:** gbrain connects via direct PostgreSQL connection string
(`DATABASE_URL`), not the Supabase REST API (Kong gateway). The connection URL
should point at the Supabase Postgres service on port 5432, not Kong on port 8000.

### 7. External access
**Cloudflare Tunnel** (already deployed as `cloudflared` in the cluster). Expose
gbrain's HTTP MCP endpoint externally so it's reachable from Claude Desktop,
Claude Code, Cursor, etc.

Target URL pattern: `https://brain.{{ cluster_domain }}`

Cloudflare Access service token policy sits in front — see Decision 4.

### 8. gbrain internal LLM
**Defer / start disabled.** For the core capture+search workflow, Claude (the
client session) does the synthesis — gbrain just does retrieval and storage. The
internal LLM (used for background dream cycle: contradiction detection, citation
fixing, enrichment) is optional to get started.

If/when needed: use OpenRouter or LiteLLM proxy pointed at a Claude model, funded
by the Claude Max API allocation (available from June 2025). Do NOT configure a
separate OpenAI account just for this.

### 9. Deployment pattern
Follow the existing ArgoCD GitOps pattern exactly:
- New `kubernetes-services/additions/gbrain/` helm chart (Chart.yaml, values.yaml, templates/)
- New `kubernetes-services/additions/ollama/` helm chart
- New `kubernetes-services/templates/gbrain.yaml` ArgoCD Application (replacing `open-brain-mcp.yaml`)
- New `kubernetes-services/templates/ollama.yaml` ArgoCD Application
- Values wired via `kubernetes-services/values.yaml` with `enable_gbrain` / `enable_ollama` flags
- Ingress via the existing reusable ingress sub-chart

---

## Cluster topology (for context)

| Node | Hardware | Role | Notes |
|---|---|---|---|
| node01 | CM4 8GB | Control plane | No workloads |
| node02 | RK1 + NVMe | Worker | Available |
| node03 | RK1 + NVMe | Worker | Available |
| node04 | RK1 + NVMe | Worker | rkllama pinned here (NPU) |
| nuc2 | Intel NUC x86_64 | Worker | **ollama target** |
| ws03 | Workstation + NVIDIA | Worker | NoSchedule taint — GPU only, do not use |

---

## Execution order

### PR 1: Clean up — remove open-brain-mcp and llamacpp
- [ ] Set `enable_open_brain_mcp: false` in values.yaml (or remove the flag)
- [ ] Remove `kubernetes-services/templates/open-brain-mcp.yaml`
- [ ] Remove `kubernetes-services/additions/open-brain-mcp/`
- [ ] Remove `kubernetes-services/additions/llamacpp/`
- [ ] Remove llamacpp ArgoCD template (if separate) or disable flag
- [ ] Clean up any related values in `kubernetes-services/values.yaml`

### PR 2: Deploy gbrain and ollama
- [ ] Create private GitHub brain repo
- [ ] `kubernetes-services/additions/ollama/` helm chart
  - Deployment pinned to nuc2, CPU-only, pulls `nomic-embed-text`
  - Service on port 11434
- [ ] `kubernetes-services/additions/gbrain/` helm chart
  - Deployment replacing open-brain-mcp
  - Configured: DATABASE_URL (direct Postgres), brain repo PAT, ollama
    embedding endpoint, OAuth
  - Service on port 8000
- [ ] `kubernetes-services/templates/ollama.yaml` ArgoCD Application
- [ ] `kubernetes-services/templates/gbrain.yaml` ArgoCD Application
- [ ] Add `enable_gbrain`, `enable_ollama` flags to values.yaml
- [ ] Cloudflare Access: create service token for brain endpoint
- [ ] Cloudflare Tunnel: add `brain.{{ cluster_domain }}` route
- [ ] Supabase: verify pgvector enabled (already is), gbrain will run its own migrations
- [ ] Verify embedding dimension compatibility (768-dim vs gbrain defaults)
- [ ] Wire MCP into Claude sessions via `~/.claude/settings.json` mcpServers
  entry, including CF-Access headers

---

## What NOT to do

- Do not use the RK1 NPU for embeddings (rkllama is flaky, different driver stack)
- Do not use the workstation GPU (gaming machine, NoSchedule taint)
- Do not use Gemini API (Google Cloud billing is opaque, separate account needed)
- Do not use OpenAI embeddings (unnecessary new subscription)
- Do not edit `devcontainer.json` automatically — always print a snippet to paste
- Do not migrate data from the existing `thoughts` table — clean start
- Do not run workloads on node01 (control plane)
- Do not wire through oauth2-proxy/Dex — unnecessary complexity given gbrain's
  built-in OAuth and Cloudflare Access service tokens

---

## Reference: existing open-brain-mcp structure (to mirror)

The existing service follows this pattern — gbrain should match it:

```
kubernetes-services/
  templates/
    open-brain-mcp.yaml        # ArgoCD Application, references two sources:
                               #   1. additions/open-brain-mcp (helm)
                               #   2. additions/ingress (reusable sub-chart)
  additions/
    open-brain-mcp/
      Chart.yaml               # apiVersion: v2, name, version: 0.1.0
      values.yaml              # defaults for standalone helm template
      templates/
        deployment.yaml        # nodeSelector: amd64, envFrom secretRef, /health probe
        service.yaml           # ClusterIP, port 8000
        open-brain-mcp-secret.yaml  # SealedSecret
```

Key patterns to follow:
- `nodeSelector: kubernetes.io/arch: amd64` for x86 workloads
- `envFrom: secretRef` for credentials (use SealedSecrets)
- `/health` liveness + readiness probes
- Ingress via reusable `additions/ingress` sub-chart with `name`, `cluster_domain`, `service_name`, `service_port`
- ArgoCD Application with `automated: prune: true, selfHeal: true` and `CreateNamespace: true`
- `{{- if .Values.enable_X }}` guard in the ArgoCD template
