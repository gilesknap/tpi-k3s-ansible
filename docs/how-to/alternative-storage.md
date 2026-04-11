# Use an Alternative Storage Provider

This project uses **static local `local-nvme` PVs plus an NFS backup target**
as its default storage architecture. If you prefer a CSI-based solution — such
as Longhorn, Rook-Ceph, OpenEBS, or a dynamic NFS provisioner — follow this
guide to replace the defaults.

## What the default architecture gives you

The default has two layers:

- **Per-node static local PVs** (`additions/local-storage`) — one NVMe PV per
  stateful workload, pre-bound via `claimRef`, pinned with `nodeAffinity`, and
  backed by an on-disk path (`/home/k8s-data/*` on nuc2, `/var/lib/k8s-data/*`
  on RK1 nodes). `pb_decommission.yml` preserves these directories by
  default, so stateful apps survive cluster rebuilds.
- **One shared NFS PV on the NAS for backups** (`additions/backups`) — per-app
  `CronJob`s write to `/bigdisk/k8s-cluster/backups/<app>/{,weekly}` via
  `subPath`. See {doc}`backup-restore` for retention, restore recipes, and the
  manual NAS runbook ({doc}`nas-setup`).

What the default does **not** give you:

- Replicated block storage across nodes (a node loss loses that node's live data)
- A web UI for volume management
- Live (non-snapshot) block-level backups
- Automatic rebalancing when nodes are added or removed

If you need those, replace the local-nvme layer with a CSI provider.

## Step 1: Remove the static local-nvme layer

Delete the local-storage chart and ArgoCD Application template:

```bash
rm kubernetes-services/templates/local-storage.yaml
rm -rf kubernetes-services/additions/local-storage/
```

Also remove the `k8s_data_dirs` role from `pb_all.yml` (`servers` play) if
your replacement does not need the on-disk directories, and drop the role
itself:

```bash
rm -rf roles/k8s_data_dirs/
```

## Step 2: Update storage references in stateful services

Search for `local-nvme` in the templates and swap it for your provider's
StorageClass name:

```bash
grep -rn local-nvme kubernetes-services/templates/
```

Expect hits in `supabase.yaml`, `grafana.yaml`, and `open-webui.yaml`. For
each, change `storageClassName: local-nvme` (or `storageClass: local-nvme`
for Open WebUI's chart) to your provider's class.

:::{tip}
If your replacement storage provider registers itself as the **default**
StorageClass, you can remove the `storageClassName` field entirely and
Kubernetes will pick the default.
:::

## Step 3: Update the decommission playbook

`pb_decommission.yml` has no Longhorn-specific surgery — it just scales down
stateful workloads and deletes chart-owned PVCs so they re-create cleanly on
the next sync. If your replacement provider needs additional teardown
(Longhorn volumes detach, Ceph OSDs drain, etc.), add those steps to the
"Scale down workloads and delete chart-owned PVCs" play.

## Step 4: Adjust decommission retention

The default decommission preserves `/home/k8s-data` and `/var/lib/k8s-data`
unless you pass `-e wipe_local_data=true`. If you remove the local-nvme layer
entirely, these paths become irrelevant and the gated wipe task in
`pb_decommission.yml` can be removed.

## Step 5: Add your replacement storage provider

Create a new ArgoCD Application template for your CSI driver. Examples:

### Longhorn (block storage, replicated)

```yaml
# kubernetes-services/templates/longhorn.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn
  namespace: argo-cd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: kubernetes
  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn
  sources:
    - chart: longhorn
      repoURL: https://charts.longhorn.io/
      targetRevision: 1.11.1
      helm:
        values: |
          persistence:
            defaultClassReplicaCount: 3
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Add `https://charts.longhorn.io/` to `sourceRepos` in
`argo-cd/argo-project.yaml`. If you choose Longhorn, you also need to add
`open-iscsi` to the `update_packages` role's package list — Longhorn
requires it for iSCSI target presentation, and it is no longer installed
by default because the cluster dropped Longhorn.

### Dynamic NFS CSI

```yaml
# kubernetes-services/templates/nfs-csi.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nfs-csi
  namespace: argo-cd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: kubernetes
  destination:
    server: https://kubernetes.default.svc
    namespace: nfs-csi
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  sources:
    - repoURL: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
      targetRevision: "4.9.0"
      chart: csi-driver-nfs
      helm:
        valuesObject:
          storageClass:
            create: true
            name: nfs-csi
            reclaimPolicy: Retain
            server: 192.168.1.100       # Your NFS server IP
            share: /export/k8s          # Your NFS export path
```

### k3s built-in `local-path` only

`local-path-provisioner` is already installed by k3s as the cluster default
StorageClass. To use it without any static PVs, just remove the local-nvme
layer (Step 1) and change `storageClassName: local-nvme` to
`storageClassName: local-path` in the stateful templates. Note that
`local-path` binds a PVC to a specific node's `hostPath`, and those bindings
live in etcd — they are **not recoverable after a cluster rebuild**, which is
why this project ships static PVs with `claimRef` instead.

## Step 6: Commit and push

```bash
git add -A
git commit -m "Replace static local PVs with <your-provider>"
git push
```

ArgoCD will provision your replacement storage provider. Stateful workloads
will re-create their PVCs against the new StorageClass.

## Common alternative providers

| Provider | Best for | Notes |
|----------|----------|-------|
| `local-path` | Single-node, dev clusters | Built into K3s, no replication, not rebuild-safe |
| Longhorn | Replicated block storage on commodity nodes | Heavy; needs iSCSI |
| NFS CSI | Shared storage, NAS | Requires external NFS server; live data on NFS not ideal for Postgres |
| Rook-Ceph | Production, multi-node | Complex setup, high resource usage |
| OpenEBS | Flexible, lightweight | Multiple engine options |
| Democratic CSI | iSCSI/NFS to TrueNAS | Good for home labs with NAS |
