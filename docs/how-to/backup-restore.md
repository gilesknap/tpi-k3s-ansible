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
| Sealed Secrets private keys | `kube-system` namespace | nightly age-encrypted CronJob → NFS NAS |
| Let's Encrypt wildcard certificate and ACME account key | `cert-manager` namespace | nightly age-encrypted CronJob → NFS NAS |
| Minecraft CurseForge API keys (`<world>-curseforge`) | `minecraft` namespace | nightly age-encrypted CronJob → NFS NAS |
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

(secrets-backup)=
## Secrets that are not in git

Most Secrets come from SealedSecrets in git, or are generated on a rebuild.
A few cannot be: the sealed-secrets controller's own private keys (without
them no SealedSecret in git can be decrypted), and Secrets that controllers
create at run time. The `secrets-backup` CronJob in the `backups` app exports
these every night, encrypted with [age](https://github.com/FiloSottile/age)
to the same **public** key as the etcd backup (`backup_age_recipient` in
`group_vars/all.yml`).

### What is backed up

Each bundle is a tar of one re-appliable YAML file per source, plus a
`MANIFEST` listing every Secret and the files' sha256 sums. The sources are
set in `secrets_backup.sources` in
`kubernetes-services/additions/backups/values.yaml`:

| File in the bundle | Secrets | Why they are not in git |
|--------------------|---------|-------------------------|
| `sealed-secrets-keys.yaml` | `kube-system`, label `sealedsecrets.bitnami.com/sealed-secrets-key` (the controller adds a key every 30 days and keeps the old ones) | The keys that decrypt every SealedSecret |
| `cert-manager.yaml` | `cert-manager/wildcard-tls`, `cert-manager/letsencrypt-prod` | The issued wildcard certificate, and the ACME account key of the `letsencrypt-prod` ClusterIssuer. Restoring them avoids a re-issue, and Let's Encrypt's rate limits |
| `minecraft-curseforge.yaml` | `minecraft/<world>-curseforge` (only while `enable_minecraft` is true) | Rendered by the Minecraft dashboard's itzg chart for each world |

The YAML has `managedFields`, `uid`, `resourceVersion`,
`creationTimestamp`, `ownerReferences` and the last-applied annotation
removed, so `kubectl apply` puts it straight into a new cluster.

### How it works

Every night at 22:30 Europe/London, before the upgrade windows, the Job:

1. reads the Secrets with `kubectl` and strips them to re-appliable YAML in
   a RAM-backed (`medium: Memory`) `emptyDir`, so no plaintext reaches a
   disk;
2. pipes a tar of them through `age -r <backup_age_recipient>`;
3. copies the result to `backups/secrets/.<name>.partial` on the NAS, reads
   it back to check its sha256, then renames it to
   `secrets-<UTC time>.tar.age`, with a `.sha256` file beside it;
4. keeps the newest 30 bundles (by mtime), deletes `.partial` files over a
   day old, and rewrites `LATEST` (bundle name, time, sha256 and counts).

It fails, and writes nothing, if `backup_age_recipient` is not an age
public key, if a Secret cannot be read, if no sealed-secrets key or either
cert-manager Secret is found, or if `backups/secrets/` is missing.

**Access.** The `secrets-backup` ServiceAccount has one Role per
namespace, and nothing else:

| Namespace | Verbs | Scope |
|-----------|-------|-------|
| `cert-manager` | `get` | `resourceNames: [wildcard-tls, letsencrypt-prod]` |
| `kube-system` | `list` | all Secrets: RBAC cannot restrict by label, and the key names change every 30 days |
| `minecraft` | `list` | all Secrets: the names depend on the worlds |

`list` returns the Secrets' data, so in `kube-system` and `minecraft` the
job could read every Secret, not only the ones it keeps. That is as narrow
as RBAC goes for Secrets selected by label or name pattern; it is limited to
`list` (no `get` or `watch`) in those two namespaces. The API token is
mounted only into the backup container, not into the initContainer that
downloads age.

**Image.** Both containers use `alpine/k8s`, pinned by tag and digest
(kubectl, jq, yq and bash, for amd64 and arm64). age is not in it, so an
initContainer downloads the pinned age release for the node's architecture
and refuses it unless it matches the sha256 in `secrets_backup.age`.

### One-time setup

1. Create `backups/secrets/` on the NAS ({ref}`secrets-backup-nas-directory`).
2. Set `backup_age_recipient` in `group_vars/all.yml` (see
   {ref}`etcd-offsite-backup`), then run
   `ansible-playbook pb_all.yml --tags cluster`: the root app passes the
   key down to the `backups` app.
3. Take a backup now, and check it:

   ```bash
   kubectl -n backups create job --from=cronjob/secrets-backup secrets-backup-now
   kubectl -n backups logs -f job/secrets-backup-now
   ssh nas sudo cat /share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/secrets/LATEST
   kubectl -n backups delete job secrets-backup-now
   ```

4. Prove that you can decrypt it (next section), with `tar -t` in place of
   `tar -x`.

### Decrypt a bundle

Only the private key can decrypt a bundle, so do this on the machine that
holds it. The directory on the NAS is readable only by uid 65534, hence
`sudo`:

```bash
D=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/secrets
b=$(ssh nas sudo cat "$D/LATEST" | awk '/^bundle:/ {print $2}')
ssh nas sudo cat "$D/$b" > "$b"
ssh nas sudo cat "$D/$b.sha256" | sha256sum -c -

age -d -i ~/k3s-etcd-backup.agekey "$b" | tar -t           # list
age -d -i ~/k3s-etcd-backup.agekey "$b" | tar -xO ./MANIFEST
```

To extract everything, use a private directory on a RAM disk and delete it
afterwards: the files are plaintext Secrets.

```bash
mkdir -m 700 /dev/shm/secrets
age -d -i ~/k3s-etcd-backup.agekey "$b" | tar -x -C /dev/shm/secrets
```

### Alerts

Three alerts in the `backups` app (`secrets-backup-rules.yaml`), from
kube-state-metrics' Job and CronJob metrics:

- `SecretsBackupFailed`: a `secrets-backup` Job failed, and no run has
  succeeded since it started.
- `SecretsBackupStale`: no successful run for 36 hours
  (`kube_cronjob_status_last_successful_time`).
- `SecretsBackupNeverSucceeded`: no successful run recorded at all, for 36
  hours.

### Restore after a rebuild

Restore the sealed-secrets keys **before the controller starts**: a
controller that starts with no key generates a new one, and the
SealedSecrets in git stay undecryptable until it is restarted. The
controller is deployed by Argo CD, so the window is after k3s is installed
and before the `cluster` tag runs:

```bash
ansible-playbook pb_all.yml --skip-tags cluster    # nodes and k3s, no Argo CD yet

# Straight from the bundle into the cluster: no plaintext on disk.
age -d -i ~/k3s-etcd-backup.agekey "$b" | tar -xO ./sealed-secrets-keys.yaml \
  | kubectl apply -f -
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key

ansible-playbook pb_all.yml --tags cluster          # Argo CD, then everything else
```

The controller loads every labelled key when it starts and decrypts with any
of them, so the SealedSecrets in git decrypt as they are and need no re-seal.
(The restored keys all look new to it, so its 30-day key rotation counts from
the restore.)

If the controller is already running (for example after a full
`pb_all.yml` run), apply the keys anyway and restart it so it loads them:

```bash
age -d -i ~/k3s-etcd-backup.agekey "$b" | tar -xO ./sealed-secrets-keys.yaml \
  | kubectl apply -f -
kubectl -n kube-system rollout restart deployment/sealed-secrets
```

The cert-manager Secrets go in before cert-manager first issues a
certificate, so it finds a valid one and re-uses the ACME account:

```bash
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
age -d -i ~/k3s-etcd-backup.agekey "$b" | tar -xO ./cert-manager.yaml \
  | kubectl apply -f -
```

The CurseForge Secrets are re-rendered when the dashboard starts each
world. If the API key itself has been lost, read it from the bundle:

```bash
age -d -i ~/k3s-etcd-backup.agekey "$b" | tar -xO ./minecraft-curseforge.yaml \
  | yq '.items[0].data["cf-api-key"]' | base64 -d
```

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
   `backup_age_recipient`, so no plaintext is written to disk;
3. mounts the NAS share, copies the result to
   `backups/etcd/k3s-etcd-<node>-<UTC time>.tar.age`, checks the copy's
   checksum, updates `LATEST`, and keeps the newest 14;
4. ships the newest `pre-upgrade-*` snapshot (taken by an automatic k3s
   upgrade) once to `backups/etcd/pre-upgrade/`, keeping 4;
5. writes `k3s_etcd_backup_*` metrics for node-exporter's textfile
   collector.

Nothing on the cluster holds the private key, so the cluster can make and
check backups but cannot decrypt them. If `backup_age_recipient` is
empty the job fails on every run and uploads nothing. The same key encrypts
the {ref}`secrets-backup`; to use a different key for etcd alone, set
`etcd_backup_age_recipient`.

#### One-time setup

1. On your own machine, create the key pair. `age-keygen -o
   ~/k3s-etcd-backup.agekey` prints the public key (`age1...`). Keep the key
   file offline, in two places; without it no backup can be decrypted.
2. Set the public key in `group_vars/all.yml`:

   ```yaml
   backup_age_recipient: age1...
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
3. Run `ansible-playbook pb_all.yml -e do_flash=true --skip-tags cluster`.
4. Restore the sealed-secrets keys and the cert-manager Secrets from the
   newest secrets bundle ({ref}`secrets-backup`), then run
   `ansible-playbook pb_all.yml --tags cluster`, which deploys Argo CD and
   the sealed-secrets controller. Without the old keys, every SealedSecret
   must be re-sealed ({doc}`manage-sealed-secrets`).
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
