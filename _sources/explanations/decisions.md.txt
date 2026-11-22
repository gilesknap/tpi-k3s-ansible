# Decision records

Architecture Decision Records (ADRs) for this cluster, in Michael Nygard's
lightweight format: the context, the decision and its consequences, written
at the time the choice was made.

They are historical records. An ADR's body is never rewritten when the cluster
moves on; at most its status line changes, or a later ADR supersedes it. So
most of them no longer describe what runs: Open Brain, the self-hosted Supabase
stack and Longhorn have all been removed. For the cluster as it is today, read
the {doc}`architecture pages </explanations/architecture>`.

| No. | Decision | Status | Describes the cluster today? |
|-----|----------|--------|------------------------------|
| 1 | {doc}`Record architecture decisions <decisions/0001-record-architecture-decisions>` | Accepted | Yes |
| 2 | {doc}`Self-host the full Supabase stack for Open Brain <decisions/0002-open-brain-supabase-self-hosted>` | Superseded: Open Brain and Supabase removed | No, history |
| 3 | {doc}`Hybrid intelligence architecture <decisions/0003-hybrid-intelligence-architecture>` | Superseded: Open Brain removed | No, history |
| 4 | {doc}`x-brain-key header auth for the MCP API <decisions/0004-mcp-auth-brain-key>` | Superseded by ADR 10 | No, history |
| 5 | {doc}`Taint workstation nodes <decisions/0005-ws03-workstation-taint>` | Accepted (applied) | Yes: `ws03` carries `workstation=true:NoSchedule` |
| 6 | {doc}`Supabase database storage on the NAS via NFS <decisions/0006-supabase-nfs-storage>` | Superseded: Supabase removed | No, history |
| 7 | {doc}`Pin Supabase to x86 nodes <decisions/0007-supabase-x86-node-affinity>` | Superseded: Supabase removed | No, history |
| 8 | {doc}`Defer the embedding pipeline to phase 2b <decisions/0008-embedding-pipeline-deferred>` | Superseded: Open Brain removed | No, history |
| 9 | {doc}`Exclude workstation nodes from Longhorn storage <decisions/0009-longhorn-exclude-workstations>` | Superseded by ADR 12 | No, history |
| 10 | {doc}`MCP protocol with GitHub OAuth for Claude.ai <decisions/0010-mcp-protocol-github-oauth>` | Superseded: Open Brain MCP server removed | No, history |
| 11 | {doc}`MinIO for Open Brain file attachments <decisions/0011-minio-file-attachments>` | Superseded: Open Brain and Supabase removed | No, history |
| 12 | {doc}`Drop Longhorn in favour of static local PVs and NFS backups <decisions/0012-drop-longhorn>` | Accepted | Yes, except for scrap, which ADR 13 amends ({doc}`/explanations/architecture/storage`) |
| 13 | {doc}`scrap runs on any node: Litestream on NFS <decisions/0013-scrap-litestream-on-nfs>` | Accepted | Yes ({doc}`/explanations/architecture/backups`) |
| 14 | {doc}`A second, immutable off-site copy on Backblaze B2 <decisions/0014-immutable-offsite-copy>` | Accepted | Yes, once `offsite_backup.b2.enabled` is on ({doc}`/explanations/architecture/backups`) |
| 15 | {doc}`Cilium replaces flannel, kube-proxy and k3s's policy controller <decisions/0015-cilium-network-layer>` | Accepted | Yes ({doc}`/explanations/architecture/networking`) |
| 16 | {doc}`Cilium's Gateway API replaces ingress-nginx <decisions/0016-cilium-gateway-api>` | Accepted | Yes ({doc}`/explanations/architecture/networking`) |

```{toctree}
:maxdepth: 1

decisions/0001-record-architecture-decisions
decisions/0002-open-brain-supabase-self-hosted
decisions/0003-hybrid-intelligence-architecture
decisions/0004-mcp-auth-brain-key
decisions/0005-ws03-workstation-taint
decisions/0006-supabase-nfs-storage
decisions/0007-supabase-x86-node-affinity
decisions/0008-embedding-pipeline-deferred
decisions/0009-longhorn-exclude-workstations
decisions/0010-mcp-protocol-github-oauth
decisions/0011-minio-file-attachments
decisions/0012-drop-longhorn
decisions/0013-scrap-litestream-on-nfs
decisions/0014-immutable-offsite-copy
decisions/0015-cilium-network-layer
decisions/0016-cilium-gateway-api
```
