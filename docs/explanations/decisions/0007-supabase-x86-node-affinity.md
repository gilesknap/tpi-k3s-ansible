# 7. Pin Supabase to x86 Nodes

**Status:** Accepted

## Context

Supabase container images have inconsistent ARM64 support. The community Helm
chart uses suffix-based image tags for architecture, and Kong in particular
lacks reliable ARM64 images.

## Decision

Set `nodeSelector: kubernetes.io/arch: amd64` on all Supabase components.
Clusters with only one x86 node will concentrate all Supabase pods there;
adding a second dedicated x86 worker distributes the load.

*Example: in the author's cluster, Supabase initially ran on ws03 (a
workstation) and later moved to nuc2 (a dedicated Intel NUC worker).*

## Consequences

- All Supabase pods require at least one x86/amd64 node in the cluster
- Total Supabase footprint is ~2.5 GB RAM across all components
- ARM migration possible but not prioritized (Kong lacks reliable ARM64 images)
- If the only x86 node is a workstation, a toleration is needed temporarily;
  remove it once a dedicated x86 worker is available (see ADR 0005)
