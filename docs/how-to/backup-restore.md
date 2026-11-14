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
| Sealed Secrets private keys | `kube-system` namespace | nightly age-encrypted export → NFS NAS, plus your own offline copy |
| etcd snapshot + k3s token | control plane | nightly age-encrypted bundle → NFS NAS |
| Admin passwords | `admin-auth` secrets (manual) | re-create from password manager |
| Cloudflare OpenTofu state + passphrase | `cloudflare/terraform.tfstate` (gitignored), `cloudflare/.secrets/state-passphrase` | copy to the NAS / password manager; recreatable by import ({doc}`cloudflare-as-code`), except the tunnel secret: a re-created state makes a new one, so its first apply rotates the tunnel token (reseal with `just cf-seal-tunnel-token`, restart cloudflared) |
| Default dynamic NFS volumes (`nfs-stable`), incl. Minecraft worlds | NFS NAS, `<nfs_csi.stable_share>/<namespace>/<pvc>` | survive a rebuild in place; no cluster backup (Minecraft: dashboard snapshots) |
| Scratch dynamic NFS volumes (`nfs-rwx`) | NFS NAS, `<nfs_csi.share>/<namespace>/<pvc>-<pv>` | not re-bound after a rebuild; the folders stay on the NAS |

The backups on the NAS, and the Minecraft data, also go off site: a nightly
job copies them, age-encrypted, to Google Drive. Not everything in the table
does; {ref}`offsite-backup` lists what does and does not.

## Stateful app data: CronJob-to-NFS backups

The `backups` ArgoCD Application (`kubernetes-services/templates/backups.yaml`)
deploys one daily and one weekly CronJob per stateful workload. Each CronJob
mounts a single NFS PV — `/bigdisk/k8s-cluster` on the NAS — with a
workload-specific `subPath` so it only sees its own target subdirectory.

| Workload | Backup method | NFS path |
|----------|---------------|----------|
| Grafana sqlite | `sqlite3 .backup` on `/var/lib/k8s-data/grafana`, tarred with `provisioning/` | `backups/grafana/<date>_<HHMM>.tar.gz` (daily), `backups/grafana/weekly/<date>.tar.gz` (weekly), each containing `grafana.db` and `provisioning/` |
| Jellyfin database and config | `sqlite3 .backup` of the database, plus the config, plugins and library definitions, from its config volume (not subtitles or metadata); see {doc}`jellyfin` | `backups/jellyfin/<date>_<HHMM>.tar.gz` (daily), `backups/jellyfin/weekly/<date>.tar.gz` (weekly) |

Prometheus is deliberately **not** backed up — metrics are reconstructible
via re-scrape, and the snapshot-API dance is not worth the complexity.

### Retention

- Grafana: daily at `02:45`, weekly on Sunday at `03:45` (cluster time).
  Jellyfin: daily at `01:45`, weekly on Sunday at `01:50` (Europe/London).
- Daily backups older than 7 days and weekly backups older than 28 days are
  deleted (`find -mtime +7` / `+28`).

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

Each Grafana backup is a gzip tarball holding a consistent `sqlite3 .backup`
snapshot of `grafana.db` plus the `provisioning/` directory. To restore one:

1. **Stop Grafana through Git.** Set the grafana sub-chart's `replicas: 0`
   in `kubernetes-services/templates/grafana.yaml` (under
   `valuesObject.grafana`), commit, push and let ArgoCD sync. Scaling the
   StatefulSet with `kubectl` does not stick: ArgoCD's self-heal reverts it.

2. **Restore in a one-off pod** in the `monitoring` namespace that mounts the
   Grafana PVC and the NAS backup directory. Fill in your NAS address and
   `nfs.cluster_share_path` from `kubernetes-services/values.yaml`, and the
   backup to restore:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: grafana-restore
     namespace: monitoring
   spec:
     restartPolicy: Never
     securityContext:
       runAsUser: 472
       runAsGroup: 472
     containers:
       - name: restore
         image: alpine:3.24
         command:
           - sh
           - -c
           # weekly: /backup/weekly/<YYYY-MM-DD>.tar.gz. Removing stale
           # SQLite journal/WAL files stops them replaying onto the restore.
           - >-
             rm -f /data/grafana.db-journal /data/grafana.db-wal /data/grafana.db-shm &&
             tar -xzf /backup/<YYYY-MM-DD_HHMM>.tar.gz -C /data grafana.db
         volumeMounts:
           - { name: data, mountPath: /data }
           - { name: backup, mountPath: /backup, readOnly: true }
     volumes:
       - name: data
         persistentVolumeClaim:
           claimName: storage-grafana-prometheus-0
       - name: backup
         nfs:
           server: <nfs.server>
           path: <nfs.cluster_share_path>/backups/grafana
           readOnly: true
   ```

   The PVC is bound to a `local-nvme` PV, so the pod lands on the Grafana
   node by itself. Check `kubectl -n monitoring logs grafana-restore`, then
   `kubectl -n monitoring delete pod grafana-restore`.

3. **Start Grafana again** by reverting the `replicas: 0` commit and pushing.

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

(sealed-secrets-key-backup)=
## Sealed Secrets key backup

The sealed-secrets controller decrypts SealedSecrets with private keys
kept as Secrets in `kube-system`. A rebuilt cluster's controller makes a
new key, and the SealedSecrets in Git cannot be decrypted without the old
ones.

**A planned rebuild does not need the old keys.** The rebuild path reads
the plaintext values from the old cluster (`scripts/export-external-creds`)
and reseals everything against the new key ({doc}`manage-sealed-secrets`).
The key backup is for a cluster that died: with it you can restore the keys
before the controller starts, so the SealedSecrets in Git decrypt as they
are, or decrypt them offline with
`kubeseal --recovery-unseal --recovery-private-key <keys.yaml>`
({doc}`manage-sealed-secrets`). That pair, the SealedSecrets in Git and the
key backup, is the recovery copy of every sealed credential. The `.env`
that a rebuild exports is not: delete it once the rebuild is verified.

### Key renewal is off

The controller's automatic key renewal (every 30 days by default) is turned
off (`keyrenewperiod: "0"` in `kubernetes-services/templates/sealed-secrets.yaml`).
Renewal only adds a key: it keeps every old key, so it does not cut off
anything sealed with them, and it re-encrypts nothing. What it did do was
make every offline key export stale within a month. With it off, an export
stays valid until you rotate the key by hand
({ref}`rotate-sealing-key`) or rebuild the cluster.

### Nightly encrypted copy on the NAS

The nightly etcd backup ({ref}`etcd-offsite-backup`) also exports the key
Secrets, encrypted with age to the same public key as the etcd bundles:

- `backups/etcd/sealed-secrets-keys.yaml.age`: the current keys, replaced
  each night;
- `backups/etcd/sealed-secrets-keys/sealed-secrets-keys-<UTC time>.yaml.age`:
  dated copies, the newest 14 kept.

The run fails, and `K3sEtcdBackupFailed` fires, if it finds no keys or
cannot export them; the etcd bundle is still uploaded.

### Keep an offline copy

The NAS copy is lost with the NAS, so keep one elsewhere too (password
manager, encrypted drive), encrypted to your age key. Pipe the export
straight into age, so the plaintext keys never touch a disk:

```bash
f=sealed-secrets-keys-$(date +%F).yaml.age
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  | age -r age1... -o "$f"   # your etcd_backup_age_recipient
# Check it holds the keys (prints a count, not the keys):
age -d -i ~/k3s-etcd-backup.agekey "$f" | grep -c '^  kind: Secret$'
```

A new file per export means a failed `kubectl` cannot overwrite a good copy;
the count must match `kubectl get secret -n kube-system -l
sealedsecrets.bitnami.com/sealed-secrets-key`.

Or copy the nightly file from the NAS. Right after a rebuild or a rotation
it still holds the old keys, so run `just etcd-backup-now` first. Re-export the offline copy after
every manual rotation and **after every cluster rebuild**: a rebuild makes
a new key and reseals everything with it, so the old copy no longer opens
the SealedSecrets in Git.

:::{warning}
The decrypted keys can decrypt every SealedSecret sealed with them. Never
store them unencrypted, and never in Git.
:::

### Restore the keys

Fetch the nightly copy and check it, or use your offline copy:

```bash
NAS_DIR=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/etcd
scp "nas:$NAS_DIR/sealed-secrets-keys.yaml.age" \
  "nas:$NAS_DIR/sealed-secrets-keys.yaml.age.sha256" .
sha256sum -c sealed-secrets-keys.yaml.age.sha256
```

Put the keys back before the controller starts, or restart it afterwards
so that it loads them:

```bash
age -d -i ~/k3s-etcd-backup.agekey sealed-secrets-keys.yaml.age \
  | kubectl apply -f -
kubectl -n kube-system rollout restart deployment/sealed-secrets
```

If the controller had already made a key of its own, it keeps it and seals
new secrets with it, since its certificate is the newest; the restored keys
still decrypt the SealedSecrets in Git.

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
5. exports the sealed-secrets keys, encrypted the same way, to
   `backups/etcd/sealed-secrets-keys.yaml.age`, with dated copies in
   `backups/etcd/sealed-secrets-keys/` ({ref}`sealed-secrets-key-backup`);
6. writes `k3s_etcd_backup_*` metrics for node-exporter's textfile
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
cover this backup: `K3sEtcdBackupFailed` (the last run failed, including
a failed sealed-secrets key export),
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

(offsite-backup)=
## Off-site copy to Google Drive

Every backup above ends up on the NAS, so a lost NAS would take them all.
The `offsite-backup` CronJob (`additions/backups/templates/cronjob-offsite.yaml`,
values in `offsite_backup` in `kubernetes-services/values.yaml`) copies them
to a folder in a personal Google Drive each night, at 05:30 Europe/London,
after the other nightly backups. It uses [rclone](https://rclone.org/).

### What goes up, and what does not

Into the folder `offsite_backup.drive_root` (default `home-cluster-offsite`):

| On Drive | From | When |
|----------|------|------|
| `backups/<path>.age` | each file under `backups/` on the NAS (the Grafana and Jellyfin tarballs, e.g. `backups/grafana/<date>_<HHMM>.tar.gz.age`); files that already end `.age` (the etcd bundles, `pre-upgrade/` snapshots and dated sealed-secrets key exports) go up as they are | once, the first night it is there |
| `backups/<run>.tar.age` | each run directory of `offsite_backup.backups.run_dirs` (scrap's daily, monthly and curated runs) as one tarball | once it has its `COMPLETE` marker |
| `backups/<run>.incomplete.tar.age` | a run directory with no `COMPLETE` marker | once the run folder is two days old (its modification time) |
| `minecraft/nightly/minecraft-<UTC time>.tar.age` | the Minecraft dashboard's store (`<nfs.cluster_share_path>/<minecraft.store_subdir>`: its backups, snapshots and state), and from `nfs_csi.stable_share` the live worlds' volumes (`minecraft/`) and the deleted worlds (`archived-minecraft/`) | every night; the newest `offsite_backup.minecraft.keep` (7) are kept |
| `minecraft/archive/minecraft-archive-<fingerprint>.tar.age` | the world archive (`minecraft.archive_path`) | once; again only if its files change (the fingerprint hashes their names and sizes) |

A backup is uploaded when no file of its name is on Drive yet, so each goes
up once. Skipped: dotfiles, files written in the last 10 minutes, and
`offsite_backup.backups.exclude`, the files rewritten in place each night
(`etcd/LATEST` and the undated `sealed-secrets-keys.yaml.age`, whose dated
copies are uploaded).

**Not** copied off site:

- the live scrap data volume (`scrap-data`, with the database's Litestream
  replica): only scrap's backup runs are, so up to a day of pages can be lost
  with the NAS;
- every other `nfs-stable` and `nfs-rwx` volume (other namespaces' dynamic
  NFS claims);
- the `local-nvme` PVs themselves (only the Grafana and Jellyfin backups made
  from them); Prometheus is not backed up at all;
- the Cloudflare OpenTofu state and its passphrase, and the admin passwords;
- media, photos and anything else on the NAS outside the paths above.

The worlds are copied while they run. A world whose server was mid-write
can need the copy from the night before, or one of the dashboard's own
backups (in the store, so in the same tarball). If tar fails because a file
changed under it (an autosave), the tarball is retried, up to 3 times.

### How it is kept safe

- **Encrypted before it leaves.** Every file is encrypted with
  [age](https://github.com/FiloSottile/age) to `offsite_backup.age_recipient`,
  the same public key as the etcd backup (`etcd_backup_age_recipient`; one
  key opens every backup, and `just check` fails if the two differ). The
  cluster holds only the public key. Files are streamed through `age` into
  `rclone rcat`, so nothing decrypted is staged anywhere.
- **Least privilege.** rclone's token has the `drive.file` scope: it sees
  and changes only the files it created, nothing else in the Drive. That
  includes deleting them: someone who takes over the cluster cannot read
  the off-site copy, but could delete it.
- **Add only.** The job never mirrors a deletion: a backup deleted on the
  NAS, by its own retention or by a wiped or encrypted NAS, stays on Drive.
  The only deletions are its own pruning, of files it made:
  - `backups/`: a file is deleted only when **all** of these hold: its
    source is no longer on the NAS; it was uploaded over
    `offsite_backup.backups.prune_days` (180) days ago; and it is not among
    the `keep_min` (4) newest of its series. A series is the files of one
    folder whose names differ only in their date or time (all of one node's
    etcd bundles, say); a `.sha256` sidecar counts with its bundle. So the
    newest copies of each backup always stay, however old. `0` turns
    pruning off. A run with any error (an unreadable folder, a failed
    upload, a failed listing) prunes nothing, and an empty `backups/` (a
    missing mount, or a wiped NAS) stops the run before it uploads or prunes
    anything.
  - `minecraft/nightly/`: all but the newest `keep`, and only after a good
    upload. A tarball under `min_size_percent` (50) of the largest copy on
    Drive, or a listing that fails, fails the run and stops the pruning, so
    a wiped or half-mounted source cannot push the good copies out. After
    deleting a lot of worlds on purpose, delete the larger copies on Drive
    by hand, or the job keeps failing.
  - `minecraft/archive/` is never pruned.

  Pruned files are deleted outright, not moved to the Drive's trash, where
  they would still count against the quota.
- **Partial uploads never count.** Each stream goes to a `.partial-` name
  and is renamed only once the whole pipeline has succeeded, so a cut-off
  upload is never taken for a complete one and is retried the next night.

An init container makes the Drive folders first, one at a time: Drive
allows two folders of one name, so two containers making the same missing
folder at once could split the backups between them. Then two containers
run side by side, because the NAS squashes root and no one user can read
everything: `backups` runs as `nobody` (65534), which owns the root-written
etcd bundles, and `minecraft` as uid 1000, which owns the worlds. Either
failing fails the Job, which is retried once; a retry uploads only the
backups still missing, and skips the Minecraft nightly if one from the same
UTC day is already on Drive. The first run uploads several GB and may take hours; a run
stopped by `deadline_hours` is carried on by the next one.

### Space on Drive

In the steady state the folder holds:

- every backup now on the NAS, plus each one deleted from the NAS in the
  last `prune_days`: about `prune_days` times the NAS's new backups per day;
- `keep` nightly Minecraft tarballs, each about the size of the store and
  the worlds;
- one archive tarball (more if the archive changes).

For example, with about 240 MB of new backups a day (etcd 50 MB, Jellyfin
70 MB, scrap 120 MB), a 3.6 GB Minecraft tarball and a 5.8 GB archive, the
defaults come to about 43 + 25 + 6 = 75 GB. A free 15 GB Google account
needs less: lower `prune_days` (30 gives about 7 GB of backups) and
`offsite_backup.minecraft.keep` (2 gives about 7 GB).

### Alerts

`kubernetes-services/additions/grafana/offsite-backup-rules.yaml` alerts
from kube-state-metrics' CronJob and Job series, so nothing fires while the
CronJob is disabled:

- `OffsiteBackupFailed`: the newest run failed. A finished Job is deleted
  after a day (`ttlSecondsAfterFinished`), and only the last failed one is
  kept, so this and the stock `KubeJobFailed` clear after a day;
  `OffsiteBackupStale` then fires if the job keeps failing.
- `OffsiteBackupStale`: no successful run for 36 hours.
- `OffsiteBackupNeverSucceeded`: the CronJob has existed for 36 hours
  without a successful run (for example, its SealedSecret did not decrypt).

### Set it up

You need a Google account with space for the backups (see above), and an
age key pair (the etcd backup's: {ref}`etcd-offsite-backup`).

1. **Create an OAuth client** in the [Google Cloud console](https://console.cloud.google.com/):
   1. Create a project (any name, e.g. `home-cluster-backup`) and enable
      the **Google Drive API** in it.
   2. Under **Google Auth Platform**, configure the consent screen as
      **External**, add your address as a test user, and then **publish
      the app to production**. A consent screen left in *Testing* issues
      refresh tokens that expire after 7 days. An unverified app is fine
      for your own account: Google warns once, and you continue.
   3. Under **Clients**, create a client of type **Desktop app** and
      download its JSON (`client_secret_<...>.json`). Keep it outside the
      repository.
2. **Seal rclone's credentials.** In the devcontainer (it has rclone):

   ```bash
   just seal-rclone-drive ~/Downloads/client_secret_<...>.json
   ```

   Open the link it prints, sign in, and allow access. Google then sends
   the browser to `http://127.0.0.1:53682/`, where `rclone authorize` is
   waiting. That address is the browser's own machine, so this works as it
   stands only when the browser runs on the host of the devcontainer (which
   uses the host's network). With the browser on another machine, first
   forward the port from that machine to the host:

   ```bash
   ssh -L 53682:127.0.0.1:53682 <devcontainer host>
   ```

   and keep that session open while you allow access. The token still goes
   only to the script. The script builds `rclone.conf` (a `[drive]` remote
   with the `drive.file` scope) in memory and pipes it through `kubeseal`
   into
   `kubernetes-services/additions/backups/templates/offsite-backup-rclone-secret.yaml`.
   Nothing secret is printed or written to disk.
3. **Turn it on.** Commit the sealed file and set
   `offsite_backup.enabled: true` in `kubernetes-services/values.yaml`. Check
   `offsite_backup.age_recipient` is your age public key. Open a PR and
   merge it.
4. **Run it once now**, rather than waiting for the night (it refuses while
   a run is going):

   ```bash
   just offsite-backup-now
   ```

   Then look in your Drive for the `home-cluster-offsite` folder, and prove
   you can decrypt a file from it (see below).

rclone refreshes its access token itself; the refresh token in the Secret
does not change. Re-run step 2 (and commit) if Google revokes it, for
example after a password change, or if you rotate the client secret.

A rebuild needs no new consent. A planned rebuild exports the sealed
`rclone.conf` with the other external credentials
(`OFFSITE_BACKUP_RCLONE_CONF_B64` in `.env`, from
`scripts/export-external-creds`) and reseals it against the new key with
the rest ({doc}`manage-sealed-secrets`). After a cluster that died, restoring
the old sealing keys ({ref}`sealed-secrets-key-backup`) makes the
SealedSecret in Git decrypt as it is.

### Restore from Drive

Download what you need, either from the Drive web page (a folder downloads
as a zip) or with rclone, on any machine with your rclone config (the
sealed one, or a fresh `rclone config` with a `drive.file` remote: a new
token from the same OAuth client sees the same files):

```bash
rclone lsf -R drive:home-cluster-offsite/backups/grafana
rclone copy drive:home-cluster-offsite/backups/grafana/<file>.tar.gz.age .
```

Then decrypt with the private key, and verify or unpack:

```bash
age -d -i ~/k3s-etcd-backup.agekey <file>.tar.gz.age > <file>.tar.gz
age -d -i ~/k3s-etcd-backup.agekey <run>.tar.age | tar -x      # a scrap run
age -d -i ~/k3s-etcd-backup.agekey minecraft-<time>.tar.age | tar -t | head
```

The etcd bundles and sealed-secrets key exports are as they were on the NAS
(`.tar.age`, `.yaml.age`): restore them as in the sections above. Put a
decrypted backup back where the restore recipes above expect it (on the
NAS, under `backups/<app>/`), or restore from it directly.

## Disaster recovery

If only the control plane is lost, restore it from the nightly etcd backup
instead: {doc}`recover-control-plane`.

To rebuild a cluster from scratch:

1. Flash and provision nodes (see tutorials).
2. Run the one-time NAS setup (`docs/how-to/nas-setup.md`) so the
   cluster-owned `/bigdisk/k8s-cluster` share exists on the NAS.
3. Run `ansible-playbook pb_all.yml -e do_flash=true`.
4. Restore the sealed-secrets keys if the old cluster died
   ({ref}`sealed-secrets-key-backup`). A planned rebuild reseals instead;
   re-export your offline key copy afterwards.
5. Re-create the `admin-auth` secrets (see {doc}`bootstrap-cluster`).
   The off-site backup's Drive credentials need nothing: the restored keys
   decrypt its SealedSecret, and a planned rebuild reseals it from `.env`
   ({ref}`offsite-backup`).
6. ArgoCD auto-syncs all services from Git.
7. If `wipe_local_data=true` was used on decommission, restore stateful
   data from the latest NFS backup under `/bigdisk/k8s-cluster/backups/`
   using the restore recipes above (or, if the NAS was lost too, from the
   off-site copy: {ref}`offsite-backup`). Otherwise, local PV data is still
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
