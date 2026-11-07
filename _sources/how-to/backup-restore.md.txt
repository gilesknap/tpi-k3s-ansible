# Backup and Restore

This guide covers the backup strategy for a cluster managed by this project.

## What needs backing up?

The key insight of a GitOps-managed cluster is that **the Git repository is the backup
for all configuration**. ArgoCD can fully reconstruct the cluster state from the repo.

What is **not** in Git and needs separate backup:

| Data | Where it lives | Backup approach |
|------|-----------------|-----------------|
| Stateful app data | static local-nvme PVs on worker nodes | nightly CronJob → NFS NAS |
| Sealed Secrets private key | `kube-system` namespace | manual export |
| etcd snapshot + k3s token | control plane | nightly age-encrypted bundle → NFS NAS |
| Admin passwords | `admin-auth` secrets (manual) | re-create from password manager |
| ArgoCD initial admin secret | `argo-cd` namespace | regenerated on install |

## Stateful app data: CronJob-to-NFS backups

The `backups` ArgoCD Application (`kubernetes-services/templates/backups.yaml`)
deploys one daily and one weekly CronJob per stateful workload. Each CronJob
mounts a single NFS PV — `/bigdisk/k8s-cluster` on the NAS — with a
workload-specific `subPath` so it only sees its own target subdirectory.

| Workload | Backup method | NFS path |
|----------|---------------|----------|
| Grafana sqlite | `sqlite3 .backup` on `/var/lib/k8s-data/grafana` | `backups/grafana/{,weekly}/<date>.db` |

Prometheus is deliberately **not** backed up — metrics are reconstructible
via re-scrape, and the snapshot-API dance is not worth the complexity.

### Retention

- Daily CronJobs run at `02:00` and keep 7 files (`find -mtime +7 -delete`).
- Weekly CronJobs run Sunday `03:00` and keep 4 files (`find -mtime +28 -delete`).

### Trigger a one-off backup

```bash
kubectl create job --from=cronjob/grafana-daily manual-$(date +%s) -n backups
kubectl logs -n backups job/manual-<timestamp> -f
```

Then verify on the NAS:

```bash
ssh nas 'ls -lh /share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/grafana/'
```

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

(If the NFS share is not pre-mounted on the node, run the copy in a
debug pod that mounts the `k8s-cluster-nfs` PVC instead.)

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

K3s runs an embedded etcd datastore on the control plane. A snapshot holds
the full cluster state, including every Secret, unencrypted.

K3s takes its own snapshots every 12 hours (00:00 and 12:00 UTC, keeping 5)
into `/var/lib/rancher/k3s/server/db/snapshots/`, but only on the control
plane: losing that node loses them too. The nightly off-node backup below
covers that case.

(etcd-offsite-backup)=
### Nightly encrypted off-node backup

The `etcd_backup` role installs a systemd timer, `k3s-etcd-backup.timer`, on
the control plane. It runs outside Kubernetes, so it keeps working when the
API server does not. Every night at 23:15 Europe/London, before the
upgrade windows, it:

1. takes a snapshot with `k3s etcd-snapshot save --name nightly`, or uses the
   newest existing snapshot if the server cannot take one;
2. streams the snapshot, the server token (needed to restore it), the node
   password and the k3s config through
   [age](https://github.com/FiloSottile/age) to the **public** key in
   `etcd_backup_age_recipient`, so no plaintext is written to disk;
3. mounts the NAS share, copies the result to
   `backups/etcd/k3s-etcd-<node>-<UTC time>.tar.age`, checks the copy's
   checksum, updates `LATEST`, and keeps the newest 14;
4. ships the newest `pre-upgrade-*` snapshot (taken by an automatic k3s
   upgrade) once to `backups/etcd/pre-upgrade/`, keeping 4;
5. writes `k3s_etcd_backup_*` metrics for node-exporter's textfile
   collector.

Nothing on the cluster holds the private key, so the cluster can make and
check backups but cannot decrypt them. If `etcd_backup_age_recipient` is
empty the job fails on every run and uploads nothing.

#### One-time setup

1. On your own machine, create the key pair. `age-keygen -o
   ~/k3s-etcd-backup.agekey` prints the public key (`age1...`). Keep the key
   file offline, in two places; without it no backup can be decrypted.
2. Set the public key in `group_vars/all.yml`:

   ```yaml
   etcd_backup_age_recipient: age1...
   ```

3. Create `backups/etcd/` on the NAS ({doc}`nas-setup`). On an existing
   share, run this on the NAS:

   ```bash
   D=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/etcd
   mkdir -p "$D/pre-upgrade" && chmod -R 0777 "$D"
   ```

4. Install the timer:

   ```bash
   ansible-playbook pb_all.yml --limit node01 --tags etcd_backup
   just etcd-backup-now
   ```

5. Prove that you can decrypt a bundle: copy it to your machine and run
   `age -d -i ~/k3s-etcd-backup.agekey <bundle> | tar -t`.

#### Alerts and manual checks

Four alerts in `kubernetes-services/additions/grafana/etcd-backup-rules.yaml`
cover this backup: `K3sEtcdBackupFailed` (the last run failed),
`K3sEtcdBackupStale` (no bundle for 36 hours),
`K3sEtcdBackupNeverSucceeded` (no bundle yet, 36 hours after the job
first reported) and `K3sEtcdBackupMetricsMissing`. To check by hand:

```bash
ssh node01 systemctl list-timers k3s-etcd-backup.timer
ssh node01 journalctl -u k3s-etcd-backup -n 20
ssh nas cat /share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/etcd/LATEST
```

### Take or list snapshots by hand

```bash
ssh node01 sudo k3s etcd-snapshot save --name manual
ssh node01 sudo k3s etcd-snapshot list
```

### Restore

If the control plane is gone, follow {doc}`recover-control-plane`.

If the node is healthy but its etcd data is damaged, restore a local
snapshot in place:

:::{warning}
Restoring replaces the entire cluster state. All changes since the snapshot
are lost.
:::

```bash
ssh node01
sudo systemctl stop k3s
sudo k3s server --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>
sudo systemctl start k3s
```

## Disaster recovery

If only the control plane is lost, restore it from the nightly etcd backup
instead: {doc}`recover-control-plane`.

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
