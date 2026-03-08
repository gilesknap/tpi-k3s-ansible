# 6. Supabase Database Storage on NAS via NFS

**Status:** Accepted

## Context

Supabase PostgreSQL needs persistent storage that survives pod restarts and
rescheduling. An existing NAS on the LAN already serves NFS exports for LLM
models (rkllama, llamacpp).

*Example: in the author's cluster, the NAS is at 192.168.1.3.*

## Decision

Use a static NFS PersistentVolume/PersistentVolumeClaim pointing to
`/bigdisk/OpenBrain` on the NAS, following the established rkllama/llamacpp
pattern.

## Consequences

- Data survives pod restarts, rescheduling, and node reboots
- Depends on NAS availability (single point of failure)
- No dynamic provisioning — PV/PVC are committed to the repo
- `persistentVolumeReclaimPolicy: Retain` prevents accidental data loss
