# 7. Pin Supabase to x86 Nodes

**Status:** Accepted

## Context

Supabase container images have inconsistent ARM64 support. The community Helm
chart uses suffix-based image tags for architecture, and Kong in particular
lacks reliable ARM64 images.

## Decision

Set `nodeSelector: kubernetes.io/arch: amd64` on all Supabase components.
Initially runs on ws03 (only x86 node); will move to nuc2 when available.

## Consequences

- All Supabase pods compete for ws03 resources (~2.5GB RAM)
- ARM migration possible but not prioritized
- Adding nuc2 will provide more x86 capacity
- Workstation toleration needed since ws03 will eventually be tainted
