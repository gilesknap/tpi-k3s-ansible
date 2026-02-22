# Use an Alternative Storage Provider

This project deploys [Longhorn](https://longhorn.io/) as the default CSI (Container
Storage Interface) provider. If you prefer a different storage solution — such as
local-path, NFS, Rook-Ceph, or OpenEBS — follow this guide.

## What Longhorn provides

Longhorn gives you:

- Replicated block storage distributed across worker nodes
- A web UI for volume management
- Volume snapshots and backups
- Automatic replica rebuilding when nodes go down

If you do not need these features, or your environment has a different storage solution,
you can replace Longhorn entirely.

## Step 1: Remove Longhorn from ArgoCD

Delete the Longhorn ArgoCD Application template and its additions:

```bash
rm kubernetes-services/templates/longhorn.yaml
rm -rf kubernetes-services/additions/longhorn/
```

## Step 2: Remove Longhorn-specific kernel settings

The `kernel-settings.yaml` DaemonSet includes iSCSI-related configuration that is
specifically for Longhorn. Review `kubernetes-services/templates/kernel-settings.yaml`
and either:

- **Delete it entirely** if you do not need the sysctl tuning:

  ```bash
  rm kubernetes-services/templates/kernel-settings.yaml
  ```

- **Edit it** to keep only the network buffer settings (`rmem_max`/`wmem_max`) and
  remove the multipathd blacklist for Longhorn iSCSI devices.

## Step 3: Remove `open-iscsi` dependency (optional)

Longhorn requires `open-iscsi` on each node. If your replacement does not need it,
you can remove it from the `update_packages` role. Edit
`roles/update_packages/tasks/main.yml` and remove `open-iscsi` from the package list.

## Step 4: Update storage references in other services

Some services request persistent volumes using Longhorn's `storageClassName`. Search
for `longhorn` references in other templates:

### Grafana / Prometheus

In `kubernetes-services/templates/grafana.yaml`, update the storage configuration:

```yaml
# Change from:
storageSpec:
  volumeClaimTemplate:
    spec:
      storageClassName: longhorn
      resources:
        requests:
          storage: 40Gi

# To your provider:
storageSpec:
  volumeClaimTemplate:
    spec:
      storageClassName: your-storage-class   # or remove to use the cluster default
      resources:
        requests:
          storage: 40Gi
```

Update both the Prometheus and Grafana volume claims in this file.

:::{tip}
If your replacement storage provider registers itself as the **default** StorageClass,
you can simply remove the `storageClassName` field entirely and Kubernetes will use
the default.
:::

## Step 5: Add your replacement storage provider

Create a new ArgoCD Application template for your CSI driver. For example, to use
the built-in K3s `local-path` provisioner (already included in K3s by default):

```yaml
# No template needed — local-path-provisioner is built into K3s
# Just remove Longhorn and update storageClassName references to "local-path"
```

For NFS:

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

## Step 6: Commit and push

```bash
git add -A
git commit -m "Replace Longhorn with <your-provider>"
git push
```

ArgoCD will remove Longhorn and deploy your replacement storage provider.

## Common alternative providers

| Provider | Best for | Notes |
|----------|----------|-------|
| `local-path` | Single-node, dev clusters | Built into K3s, no replication |
| NFS CSI | Shared storage, NAS | Requires external NFS server |
| Rook-Ceph | Production, multi-node | Complex setup, high resource usage |
| OpenEBS | Flexible, lightweight | Multiple engine options |
| Democratic CSI | iSCSI/NFS to TrueNAS | Good for home labs with NAS |
