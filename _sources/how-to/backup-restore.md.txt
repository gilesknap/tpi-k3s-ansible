# Backup and Restore

This guide covers the backup strategy for a cluster managed by this project.

## What needs backing up?

The key insight of a GitOps-managed cluster is that **the Git repository is the backup
for all configuration**. ArgoCD can fully reconstruct the cluster state from the repo.

What is **not** in Git and needs separate backup:

| Data | Where it lives | Backup approach |
|------|-----------------|-----------------|
| Persistent Volume data | Longhorn volumes on NVMe | Longhorn snapshots/backups |
| Sealed Secrets private key | `kube-system` namespace | Manual export |
| Admin passwords | `admin-auth` secrets (manual) | Re-create from password manager |
| ArgoCD initial admin secret | `argo-cd` namespace | Regenerated on install |

## Longhorn volume snapshots

Longhorn supports both **snapshots** (local, on the same nodes) and **backups**
(to external storage like NFS or S3).

### Create a snapshot

Via the Longhorn UI at **https://longhorn.your-domain.com**:

1. Navigate to **Volumes**.
2. Click on the volume name.
3. Click **Take Snapshot**.

Via `kubectl`:

```bash
kubectl apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-snapshot
  namespace: my-namespace
spec:
  volumeSnapshotClassName: longhorn-snapshot
  source:
    persistentVolumeClaimName: my-pvc
EOF
```

The `longhorn-snapshot` VolumeSnapshotClass is deployed by this project at
`kubernetes-services/additions/longhorn/volume-snapshot-class.yaml`.

### Set up recurring snapshots

In the Longhorn UI, configure recurring snapshots under **Volume → Recurring Jobs**.
This can be set per-volume or globally.

### Back up to NFS

To back up Longhorn volumes to an NFS target:

1. In the Longhorn UI, go to **Settings → Backup Target**.
2. Set the backup target URL: `nfs://nas.local:/backup/longhorn`
3. Save.

Now you can create backups (not just snapshots) that are stored externally.

## Sealed Secrets key backup

If you rebuild the cluster, the sealed-secrets controller generates a new keypair.
Existing SealedSecret YAML files in the repo will become undecryptable.

### Export the key

```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-backup.yaml
```

:::{warning}
Store this file **securely** (e.g. password manager, encrypted drive) — never in Git.
It can decrypt all your SealedSecrets.
:::

### Restore after rebuild

Before ArgoCD deploys the sealed-secrets controller on a new cluster:

```bash
kubectl apply -f sealed-secrets-key-backup.yaml
```

The new controller will pick up the restored key and can decrypt existing SealedSecrets.

## Disaster recovery

To rebuild a cluster from scratch:

1. Flash and provision nodes (see tutorials).
2. Run `ansible-playbook pb_all.yml -e do_flash=true`.
3. Restore the sealed-secrets key (if backed up).
4. Re-create the `admin-auth` secrets (see {doc}`bootstrap-cluster`).
5. ArgoCD auto-syncs all services from Git.
6. Restore Longhorn volumes from NFS backups (if configured).

The cluster will be fully operational within minutes, with only persistent data
requiring explicit restoration.
