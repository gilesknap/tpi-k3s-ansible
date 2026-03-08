# 11. MinIO for Open Brain File Attachments

**Status:** Proposed

## Context

Open Brain currently stores only text and structured metadata. As a replacement
for Obsidian / 2ndBrain, it needs to support saving images, PDFs, and other
files alongside thoughts.

Supabase Storage is already deployed in the cluster (`deployment.storage.enabled:
true`) but has no persistent blob backend — MinIO is disabled, so uploaded files
would only live on the storage pod's ephemeral filesystem and be lost on restart.

Options considered:

1. **Enable MinIO** — the S3-compatible backend already wired into the Supabase
   Helm chart. One extra pod, backed by a Longhorn PVC. Everything stays
   self-hosted.
2. **Cloudflare R2** — S3-compatible, generous free tier, no in-cluster pod.
   But adds an external dependency and moves data off the cluster.
3. **PostgreSQL large objects** — store blobs directly in Postgres. No extra
   services, but bloats the database, slows backups, and wastes Longhorn
   replication on large binary data mixed with relational data.

## Decision

Enable MinIO in the Supabase Helm chart as the S3-compatible backend for
Supabase Storage. MinIO data is persisted on a Longhorn PVC.

The MCP server uploads files through the Supabase Storage REST API (via Kong)
rather than talking to MinIO directly. This keeps authentication consistent
(service_role JWT) and leverages Supabase's built-in bucket management, RLS
policies, and signed URL generation.

File references are stored in the thought's `metadata.attachments` array as
storage paths. The actual blobs live in MinIO.

## Consequences

- Images, PDFs, and other files can be saved alongside thoughts — feature
  parity with Obsidian / 2ndBrain
- One additional pod (MinIO) and one additional Longhorn PVC (~50Gi)
- All data remains self-hosted on cluster storage
- Files are accessible via signed URLs with time-limited access
- The MCP server gains new tools (`attach_file`, `get_attachment_url`) and
  `capture_thought` gains an optional `attachments` parameter
- MinIO is a well-understood, widely-deployed component — low operational risk
- Backup strategy must now cover MinIO PVC in addition to Postgres PVC
