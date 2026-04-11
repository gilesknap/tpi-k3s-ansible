# 9. Exclude Workstation Nodes from Longhorn Storage

**Status:** Superseded by [ADR 0012](0012-drop-longhorn.md) — Longhorn has
been removed from the cluster in favour of static local-nvme PVs plus
NFS backups, so the workstation-exclusion setting no longer applies.

## Context

Workstation nodes (tagged `workstation: true` in hosts.yml) may reboot for
updates or user activity. Longhorn replica data stored on these nodes is at
risk during unplanned reboots, degrading volume health until the node returns.

## Decision

Disable Longhorn scheduling on workstation nodes and request eviction of
existing replicas. This is done via the Longhorn Node CR:

```yaml
spec:
  allowScheduling: false
  evictionRequested: true
```

The Kubernetes `workstation=true:NoSchedule` taint already prevents Longhorn's
instance-manager pods from scheduling on workstation nodes after a fresh
install, making this the natural default. The explicit Longhorn node setting
handles the transition for existing clusters where replicas were placed before
the taint was applied.

Longhorn DaemonSet components (manager, engine-image, csi-plugin) continue to
run on all nodes as they tolerate all taints by default.

## Consequences

- Longhorn will not place new replicas on workstation nodes
- Existing replicas are evicted and rebuilt on always-on nodes
- Volumes pinned to workstation nodes via PV node affinity will update to
  include other nodes once replicas are rebuilt
- Services that previously tolerated the workstation taint for storage access
  should have those tolerations removed once a dedicated worker is available
