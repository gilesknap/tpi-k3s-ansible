# 2. Self-Host Full Supabase Stack for Open Brain

**Status:** Accepted

## Context

We need persistent AI memory accessible from any AI tool via MCP (Model Context
Protocol). Options considered:

1. **Supabase Cloud** — managed, but data leaves the cluster; monthly cost
2. **Postgres + custom MCP** — minimal dependencies, but rebuilds platform features
3. **Full self-hosted Supabase** — complete platform on our hardware

## Decision

Self-host the full Supabase stack (db, auth, PostgREST, Edge Functions, Studio,
Kong) using the `supabase-community/supabase-kubernetes` Helm chart.

## Consequences

- All data stays on our NAS (privacy, no cloud dependency)
- ~2.5GB RAM footprint across all components
- Studio UI for visual database management
- Edge Functions host the MCP server without additional infrastructure
- Dependency on community Helm chart for upgrades
- Kong gateway provides unified API routing
