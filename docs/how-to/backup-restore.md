# Backup and Restore

This guide covers the backup strategy for a cluster managed by this project.

## What needs backing up?

The key insight of a GitOps-managed cluster is that **the Git repository is the backup
for all configuration**. ArgoCD can fully reconstruct the cluster state from the repo.

What is **not** in Git and needs separate backup:

| Data | Where it lives | Backup approach |
|------|-----------------|-----------------|
| Stateful app data | static local-nvme PVs on nuc2 / RK1 nodes | nightly CronJob → NFS NAS |
| Sealed Secrets private key | `kube-system` namespace | manual export |
| Admin passwords | `admin-auth` secrets (manual) | re-create from password manager |
| ArgoCD initial admin secret | `argo-cd` namespace | regenerated on install |

## Stateful app data: CronJob-to-NFS backups

The `backups` ArgoCD Application (`kubernetes-services/templates/backups.yaml`)
deploys one daily and one weekly CronJob per stateful workload. Each CronJob
mounts a single NFS PV — `/bigdisk/k8s-cluster` on the NAS — with a
workload-specific `subPath` so it only sees its own target subdirectory.

| Workload | Backup method | NFS path |
|----------|---------------|----------|
| Supabase Postgres | `pg_dump | gzip` | `backups/supabase-db/{,weekly}/<date>.sql.gz` |
| Supabase Storage | `tar -czf` on `/home/k8s-data/supabase-storage` | `backups/supabase-storage/{,weekly}/<date>.tar.gz` |
| Supabase MinIO | `tar -czf` on `/home/k8s-data/supabase-minio` | `backups/supabase-minio/{,weekly}/<date>.tar.gz` |
| Grafana sqlite | `sqlite3 .backup` on `/var/lib/k8s-data/grafana` | `backups/grafana/{,weekly}/<date>.db` |
| Open WebUI sqlite | `tar -czf` on `/var/lib/k8s-data/open-webui` | `backups/open-webui/{,weekly}/<date>.tar.gz` |

Prometheus is deliberately **not** backed up — metrics are reconstructible
via re-scrape, and the snapshot-API dance is not worth the complexity.

### Retention

- Daily CronJobs run at `02:00` and keep 7 files (`find -mtime +7 -delete`).
- Weekly CronJobs run Sunday `03:00` and keep 4 files (`find -mtime +28 -delete`).

### Trigger a one-off backup

```bash
kubectl create job --from=cronjob/supabase-db-daily manual-$(date +%s) -n backups
kubectl logs -n backups job/manual-<timestamp> -f
```

Then verify on the NAS:

```bash
ssh nas 'ls -lh /share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/supabase-db/'
```

### Restore — Supabase Postgres

Copy the gzipped dump into the running DB pod and pipe it into `psql`:

```bash
kubectl cp /path/to/local/YYYY-MM-DD.sql.gz \
  supabase/supabase-supabase-db-0:/tmp/restore.sql.gz
kubectl exec -n supabase supabase-supabase-db-0 -- \
  sh -c 'gunzip -c /tmp/restore.sql.gz | psql -U postgres'
```

Or restore from the NFS PV directly by mounting it into a debug pod:

```bash
kubectl run pg-restore -n backups --rm -it --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "psql",
        "image": "postgres:15",
        "command": ["sh", "-c", "gunzip -c /backup/$(ls -1t /backup | head -1) | psql -h supabase-supabase-db.supabase -U postgres"],
        "volumeMounts": [{"name": "nfs", "mountPath": "/backup", "subPath": "backups/supabase-db"}]
      }],
      "volumes": [{"name": "nfs", "persistentVolumeClaim": {"claimName": "k8s-cluster-nfs"}}]
    }
  }'
```

### Restore — Supabase Storage / MinIO / Open WebUI (tar archives)

Scale the owning workload to zero, untar over the local-PV hostPath, then
scale back up. Example for Supabase Storage (nuc2 hostPath
`/home/k8s-data/supabase-storage`):

```bash
# 1. Scale down
kubectl scale -n supabase deploy/supabase-supabase-storage --replicas=0

# 2. Extract on the node (NFS share is already mounted on nuc2)
ssh ansible@nuc2 '
  cd /home/k8s-data/supabase-storage &&
  sudo rm -rf ./* ./.* 2>/dev/null;
  sudo tar -xzf /mnt/nfs/k8s-cluster/backups/supabase-storage/YYYY-MM-DD.tar.gz
'

# 3. Scale back
kubectl scale -n supabase deploy/supabase-supabase-storage --replicas=1
```

(If the NFS share is not pre-mounted on the node, run the extract in a
debug pod that mounts the `k8s-cluster-nfs` PVC instead.)

### Restore — Grafana sqlite

The Grafana daily backup uses `sqlite3 .backup` (a consistent live snapshot,
unlike a raw tar of the db file). To restore:

```bash
kubectl scale -n monitoring sts/grafana-prometheus --replicas=0
ssh ansible@node03 '
  sudo cp /mnt/nfs/k8s-cluster/backups/grafana/YYYY-MM-DD.db \
          /var/lib/k8s-data/grafana/grafana.db
'
kubectl scale -n monitoring sts/grafana-prometheus --replicas=1
```

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

## etcd backup and restore

K3s uses an embedded etcd (or SQLite for single-node) datastore. Backing up
etcd preserves the full cluster state including all Kubernetes objects.

### Create an etcd snapshot

```bash
ssh node01 sudo k3s etcd-snapshot save --name manual-$(date +%Y%m%d)
```

Snapshots are stored at `/var/lib/rancher/k3s/server/db/snapshots/` on the
control plane node.

### List snapshots

```bash
ssh node01 sudo k3s etcd-snapshot list
```

### Configure automatic snapshots

K3s supports automatic etcd snapshots. Add to `/etc/rancher/k3s/config.yaml`
on the control plane:

```yaml
etcd-snapshot-schedule-cron: "0 */6 * * *"  # every 6 hours
etcd-snapshot-retention: 10
```

Restart K3s to apply:

```bash
ssh node01 sudo systemctl restart k3s
```

### Restore from snapshot

:::{warning}
Restoring replaces the entire cluster state. All changes since the snapshot
are lost.
:::

```bash
ssh node01
sudo systemctl stop k3s
sudo k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>
sudo systemctl start k3s
```

## Disaster recovery

To rebuild a cluster from scratch:

1. Flash and provision nodes (see tutorials).
2. Run the one-time NAS setup (`docs/how-to/nas-setup.md`) so the
   cluster-owned `/bigdisk/k8s-cluster` share exists on the NAS.
3. Run `ansible-playbook pb_all.yml -e do_flash=true`.
4. Restore the sealed-secrets key (if backed up).
5. Re-create the `admin-auth` secrets (see {doc}`bootstrap-cluster`).
6. ArgoCD auto-syncs all services from Git.
7. If `wipe_local_data=true` was used on decommission, restore stateful
   data from the latest NFS backup under `/bigdisk/k8s-cluster/backups/`
   using the restore recipes above. Otherwise, local PV data is still
   intact from before the rebuild and re-binds automatically.

The cluster will be fully operational within minutes, with only persistent data
requiring explicit restoration.
