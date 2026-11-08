# Backup and Restore

This guide covers the backup strategy for a cluster managed by this project.

## What needs backing up?

The key insight of a GitOps-managed cluster is that **the Git repository is the backup
for all configuration**. ArgoCD can fully reconstruct the cluster state from the repo.

What is **not** in Git and needs separate backup:

| Data | Where it lives | Backup approach |
|------|-----------------|-----------------|
| Stateful app data | static local-nvme PVs on worker nodes | nightly CronJob → NFS NAS |
| scrap | NFS NAS, database replicated by Litestream | scrap chart's CronJobs → NFS NAS, nightly copy off the NAS |
| Sealed Secrets private key | `kube-system` namespace | manual export |
| etcd snapshot + k3s token | control plane | nightly age-encrypted bundle → NFS NAS |
| Admin passwords | `admin-auth` secrets (manual) | re-create from password manager |
| ArgoCD initial admin secret | `argo-cd` namespace | regenerated on install |
| Default dynamic NFS volumes (`nfs-stable`), incl. Minecraft worlds | NFS NAS, `<nfs_csi.stable_share>/<namespace>/<pvc>` | survive a rebuild in place; no cluster backup (Minecraft: dashboard snapshots) |
| Scratch dynamic NFS volumes (`nfs-rwx`) | NFS NAS, `<nfs_csi.share>/<namespace>/<pvc>-<pv>` | not re-bound after a rebuild; the folders stay on the NAS |

## Stateful app data: CronJob-to-NFS backups

The `backups` ArgoCD Application (`kubernetes-services/templates/backups.yaml`)
deploys one daily and one weekly CronJob per stateful workload. Each CronJob
mounts a single NFS PV — `/bigdisk/k8s-cluster` on the NAS — with a
workload-specific `subPath` so it only sees its own target subdirectory.

| Workload | Backup method | NFS path |
|----------|---------------|----------|
| Grafana sqlite | `sqlite3 .backup` on `/var/lib/k8s-data/grafana` | `backups/grafana/{,weekly}/<date>.db` |
| Jellyfin database and config | `sqlite3 .backup` of the database, plus the config, plugins and library definitions, from its config volume (not subtitles or metadata); see {doc}`jellyfin` | `backups/jellyfin/{,weekly}/<date>.tar.gz` |

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
ssh ansible@node04 '
  sudo cp /mnt/nfs/k8s-cluster/backups/grafana/YYYY-MM-DD.db \
          /var/lib/k8s-data/grafana/grafana.db
'
kubectl scale -n monitoring sts/grafana-prometheus --replicas=1
```

(If the NFS share is not pre-mounted on the node, run the copy in a
debug pod that mounts the `k8s-cluster-nfs` PVC instead.)

## scrap

scrap's chart makes its own backups (see {doc}`scrap`):

- **Daily:** `scrap-backup` runs at 03:30 and keeps 7 runs.
- **Monthly:** `scrap-backup-monthly` keeps 12 runs in `monthly/`.
- **Format:** each run is a directory named like `20261019T033000Z`, with the
  database, the files and a `COMPLETE` marker.
- **Location:** the `scrap-backups-nfs` volume, at
  `/bigdisk/k8s-cluster/backups/scrap` on the NAS.
- **Off-NAS copy:** at 05:00 `scrap-backup-copy` copies the newest complete
  run to a `local-nvme` PV, keeping 3. It fails if that run is over 26 hours
  old, so a stalled backup shows as a failed Job.

Take one now:

```bash
kubectl -n scrap create job --from=cronjob/scrap-backup scrap-backup-now
kubectl -n scrap logs -f job/scrap-backup-now
```

### Restore scrap

scrap runs with Litestream: the database is restored from its replica at
every start. A plain `scrap restore` would be undone, so a restore is
**staged**. It is checked and migrated, then left at `/data/scrap.db.restored`.
The next start takes it up in place of the replica, and keeps the old replica
as `/data/litestream.retired-<time>`.

1. Stop scrap through git. Argo CD would scale it straight back up, so
   commit a pause in `kubernetes-services/templates/scrap.yaml`'s chart
   values:

   ```yaml
   nodeSelector:
     scrap-paused: "true"
   ```

   The old pod stops, and the new one stays `Pending`. The backup jobs wait
   for it, then give up after an hour.
2. Run the restore in a one-off pod (`kubectl apply -f restore.yaml`, then
   `kubectl -n scrap logs -f pod/scrap-restore`). Use the image of the scrap
   release that made the backup, or a newer one. `--force` is needed unless
   `files/` is empty; files are only ever added.

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: scrap-restore
     namespace: scrap
   spec:
     restartPolicy: Never
     automountServiceAccountToken: false
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       runAsGroup: 10001
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: restore
         image: ghcr.io/gilesknap/scrap:<version>
         args: ["restore", "/backups/<run>", "--stage", "--force"]
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities:
             drop: [ALL]
         volumeMounts:
           - {name: data, mountPath: /data}
           - {name: backups, mountPath: /backups, readOnly: true}
           - {name: tmp, mountPath: /tmp}
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: scrap-data-nfs
       - name: backups
         persistentVolumeClaim:
           claimName: scrap-backups-nfs   # or scrap-backup-copy, for the off-NAS copy
       - name: tmp
         emptyDir: {}
   ```

3. Delete the pod and revert the pause commit. Then check
   `kubectl -n scrap logs deploy/scrap -c db-init`, which should say it took
   up the staged restore, and take a backup.

Pages written since the backup are gone. Their files are still in `files/`,
but nothing refers to them, so gc only counts for 14 days after a restore.
The retired replica holds the lost rows, which can only be recovered by hand.
See scrap's
[restore with Litestream](https://gilesknap.github.io/scrap/main/how-to/deploy-kubernetes.html#k8s-restore-litestream)
for the details and the refusals you may meet.

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
4. ships each `pre-upgrade-<version>` snapshot (taken by an automatic k3s
   upgrade) once to `backups/etcd/pre-upgrade/`, keeping 4. If there are
   two for one version, it ships the earliest: a later one is a
   post-upgrade copy from a retried upgrade Job
   ({doc}`/explanations/upgrade-model`);
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
   ansible-playbook pb_all.yml --limit node02 --tags etcd_backup   # your control_plane
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
ssh node02 systemctl list-timers k3s-etcd-backup.timer
ssh node02 journalctl -u k3s-etcd-backup -n 20
ssh nas cat /share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/etcd/LATEST
```

### Take or list snapshots by hand

```bash
ssh node02 sudo k3s etcd-snapshot save --name manual
ssh node02 sudo k3s etcd-snapshot list
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
ssh node02
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
   intact from before the rebuild and re-binds automatically. scrap's
   static NFS volumes re-bind too, and its pod restores the database from
   the replica.

The cluster will be fully operational within minutes, with only persistent data
requiring explicit restoration.

Minecraft worlds need no restore: their `nfs-stable` folders on the NAS
depend only on the PVC's namespace and name, so the dashboard re-creates its
worlds with their ports and settings, and their PVCs bind to their old data.
This holds for worlds on `nfs-stable`; move older ones first
({doc}`nfs-stable-paths`). Any other claim on `nfs-stable`, the default class,
also comes back with its data. `nfs-rwx` volumes come back empty, in new
folders.
