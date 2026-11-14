# Backup and restore

The procedures for taking, checking and restoring every backup of the
cluster, and for rebuilding it after a disaster. For the overview (what is
copied where, and why) see {doc}`/explanations/architecture/backups`.

## What needs backing up

The Git repository is the backup of all configuration: ArgoCD rebuilds the
cluster's state from it. What is **not** in Git:

| Data | Where it lives | Backup |
|------|----------------|--------|
| Grafana and Jellyfin state | `local-nvme` PVs on node04 and nuc2 | nightly CronJobs to `/bigdisk/k8s-cluster/backups/` on the NAS |
| scrap | the NAS (`/bigdisk/k8s-cluster/scrap-data`), database replicated by Litestream | the scrap chart's CronJobs to `backups/scrap/`, and a nightly copy off the NAS to nuc2 |
| Sealed Secrets private keys | Secrets in `kube-system` | nightly age-encrypted export to `backups/etcd/`, plus an offline copy |
| etcd snapshot and K3s token | node02 | nightly age-encrypted bundle to `backups/etcd/` |
| Admin password | the `admin-auth` Secret (not in Git) | re-create it with `just set-admin-password` |
| Cloudflare OpenTofu state and its passphrase | `cloudflare/terraform.tfstate` and `cloudflare/.secrets/state-passphrase` (both gitignored) | not backed up by the cluster: keep a copy of the state on the NAS and the passphrase in the password manager; see below |
| `nfs-stable` volumes, including the Minecraft worlds | the NAS, `/k8s-dynamic/stable/<namespace>/<pvc>` | they survive a rebuild in place; the worlds also go off site |
| `nfs-rwx` scratch volumes | the NAS, `/k8s-dynamic/<namespace>/<pvc>-<pv>` | none: not re-bound after a rebuild (no claim uses the class today) |

The Cloudflare state can be re-created by import
({doc}`/how-to/cloudflare-as-code`), except for the tunnel secret: a
re-created state makes a new one, so its first apply rotates the tunnel
token (reseal it with `just cf-seal-tunnel-token` and restart cloudflared).

The backups on the NAS, and the Minecraft data, also go off site: a nightly
job copies them, age-encrypted, to Google Drive. Not everything in the table
does; {ref}`offsite-backup` lists what does and does not.

## Nightly timetable

| When | What | Runs as |
|------|------|---------|
| 23:15 Europe/London | etcd bundle and sealed-secrets keys | `k3s-etcd-backup.timer` on node02 |
| 00:30 Europe/London (monthly: the 1st, 00:40) | scrap | CronJobs `scrap-backup`, `scrap-backup-monthly` in `scrap` |
| 00:35 Europe/London (weekly: Sunday 00:40) | Grafana | CronJobs `grafana-daily`, `grafana-weekly` in `backups`, on node04 |
| 00:50 Europe/London | scrap's newest run, copied off the NAS | CronJob `scrap-backup-copy` in `scrap`, on nuc2 |
| 01:45 Europe/London (weekly: Sunday 01:50) | Jellyfin | CronJobs `jellyfin-daily`, `jellyfin-weekly` in `backups`, on nuc2 |
| 05:30 Europe/London | the backups on the NAS and the Minecraft data, to Google Drive | CronJob `offsite-backup` in `backups` |

Every CronJob sets `timeZone: Europe/London`. The jobs before 01:00 run
clear of the two maintenance windows that drain nodes (K3s upgrades from
01:00, kured from 02:30; {doc}`/explanations/architecture/backups`). List
them all with `kubectl get cronjobs -A`.

## Grafana and Jellyfin: CronJob-to-NFS backups

The `backups` ArgoCD Application (`kubernetes-services/templates/backups.yaml`)
deploys one daily and one weekly CronJob per workload. Each runs on the node
that holds the workload's `local-nvme` PV, reads the data from its host path
(read-only), and mounts the one NFS PV `k8s-cluster-nfs`
(`/bigdisk/k8s-cluster` on the NAS, 192.168.1.3) with a `subPath`, so it sees
only its own target directory.

| Workload | Backup method | NFS path |
|----------|---------------|----------|
| Grafana sqlite | `sqlite3 .backup` on `/var/lib/k8s-data/grafana` (node04), tarred with `provisioning/` | `backups/grafana/<date>_<HHMM>.tar.gz` (daily), `backups/grafana/weekly/<date>.tar.gz` (weekly), each containing `grafana.db` and `provisioning/` |
| Jellyfin database and config | `sqlite3 .backup` of the database, plus the config, plugins, library definitions, playlists and scheduled tasks, from its config volume, `/home/k8s-data/jellyfin` on nuc2 (not subtitles or metadata); see {doc}`/how-to/jellyfin` | `backups/jellyfin/<date>_<HHMM>.tar.gz` (daily), `backups/jellyfin/weekly/<date>.tar.gz` (weekly) |

Prometheus is deliberately **not** backed up: its metrics build up again
by scraping, and a consistent copy needs its snapshot API, which is not
worth the complexity.

### Retention

Each run deletes its own old files: daily backups older than 7 days and
weekly backups older than 28 days (`find -mtime +7` / `+28`).

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
   Grafana PVC and the NAS backup directory (`nfs.server` and
   `nfs.cluster_share_path` in `kubernetes-services/values.yaml`). Fill in
   the backup to restore:

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
           server: 192.168.1.3
           path: /bigdisk/k8s-cluster/backups/grafana
           readOnly: true
   ```

   The PVC is bound to a `local-nvme` PV, so the pod lands on node04 by
   itself. Check `kubectl -n monitoring logs grafana-restore`, then
   `kubectl -n monitoring delete pod grafana-restore`.

3. **Start Grafana again** by reverting the `replicas: 0` commit and pushing.

Jellyfin's restore is on its own page: {doc}`/how-to/jellyfin`.

## scrap

scrap's chart makes its own backups (see {doc}`/how-to/scrap`), each taken
from the database's Litestream replica (`scrap backup --from-replica`):

- **Daily:** `scrap-backup` runs at 00:30 Europe/London and keeps 7 runs.
- **Monthly:** `scrap-backup-monthly` runs at 00:40 Europe/London on the 1st
  and keeps 12 runs in `monthly/`.
- **Format:** each run is a directory named by its start time in UTC, like
  `20261119T003000Z`, with the database, the files and a `COMPLETE` marker.
- **Location:** the `scrap-backups-nfs` volume, at
  `/bigdisk/k8s-cluster/backups/scrap` on the NAS.
- **Off-NAS copy:** at 00:50 `scrap-backup-copy` copies the newest complete
  run to a `local-nvme` PV on nuc2 (`/home/k8s-data/scrap-backup-copy`),
  keeping 3. It fails if that run is over 26 hours
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

1. Stop scrap through Git. ArgoCD would scale it straight back up, so
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
and reseals everything against the new key ({doc}`/how-to/manage-sealed-secrets`).
The key backup is for a cluster that died: with it you can restore the keys
before the controller starts, so the SealedSecrets in Git decrypt as they
are, or decrypt them offline with
`kubeseal --recovery-unseal --recovery-private-key <keys.yaml>`
({doc}`/how-to/manage-sealed-secrets`). That pair, the SealedSecrets in Git and the
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

The NAS copy also goes to Google Drive ({ref}`offsite-backup`), but keep one
more outside both (password manager, encrypted drive), encrypted to the
backup age key. Pipe the export
straight into age, so the plaintext keys never touch a disk:

```bash
f=sealed-secrets-keys-$(date +%F).yaml.age
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  | age -r age1... -o "$f"   # etcd_backup_age_recipient in group_vars/all.yml
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

K3s runs an embedded etcd datastore on the control plane, node02. A snapshot holds
the full cluster state, including every Secret, unencrypted.

K3s takes its own snapshots every 12 hours (at 00:00 and 12:00, keeping 5)
into `/var/lib/rancher/k3s/server/db/snapshots/`, but only on node02:
losing that node loses them too. The nightly off-node backup below
covers that case.

(etcd-offsite-backup)=
### Nightly encrypted off-node backup

The `etcd_backup` role installs a systemd timer, `k3s-etcd-backup.timer`, on
the control plane (`control_plane` in `group_vars/all.yml`, node02). It runs outside Kubernetes, so it keeps working when the
API server does not. Every night at 23:15 Europe/London, before the
upgrade windows, it:

1. takes a snapshot with `k3s etcd-snapshot save --name nightly`, or uses the
   newest existing snapshot if the server cannot take one;
2. bundles the snapshot, the server token (needed to restore it), the node
   password and the k3s config into one tar stream, encrypted with
   [age](https://github.com/FiloSottile/age) to the **public** key in
   `etcd_backup_age_recipient`, so no plaintext leaves the node;
3. mounts the NAS share at `/mnt/k8s-cluster` (only while it runs), copies the result to
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

This is done; it is repeated only for a new key pair or a new NAS.

1. On a machine outside the cluster, create the key pair. `age-keygen -o
   ~/k3s-etcd-backup.agekey` prints the public key (`age1...`). Keep the key
   file offline, in two places; without it no backup can be decrypted.
2. Set the public key in both places that hold it, in one commit:
   `group_vars/all.yml` for this backup, and `kubernetes-services/values.yaml`
   for the off-site copy ({ref}`offsite-backup`). `just check` and a
   pre-commit hook (`scripts/check-age-recipient`) fail if the two differ.

   ```yaml
   # group_vars/all.yml
   etcd_backup_age_recipient: age1...
   # kubernetes-services/values.yaml
   offsite_backup:
     age_recipient: age1...
   ```

3. Create `backups/etcd/` on the NAS ({doc}`/how-to/nas-setup`). On an existing
   share, run this on the NAS:

   ```bash
   D=/share/CACHEDEV1_DATA/bigdisk/k8s-cluster/backups/etcd
   mkdir -p "$D/pre-upgrade" && chmod -R 0777 "$D"
   ```

4. Install the timer:

   ```bash
   ansible-playbook pb_all.yml --limit node02 --tags etcd_backup
   just etcd-backup-now
   ```

5. Prove that a bundle decrypts: copy it to the machine with the key and run
   `age -d -i ~/k3s-etcd-backup.agekey <bundle> | tar -t`.

When a new key pair replaces an old one, keep the old private key. Nothing
is re-encrypted: every bundle and export already on the NAS, and every file
already on Drive, opens only with the key it was made with, and Drive keeps
the newest copies of each backup and the Minecraft archive indefinitely.
Step 4 switches the etcd backup to the new key; the off-site job follows
once ArgoCD has synced the merged `values.yaml`. Then make a new offline copy
of the sealed-secrets keys, encrypted to the new key
({ref}`sealed-secrets-key-backup`).

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

If the control plane is gone, follow {doc}`/how-to/recover-control-plane`:
it restores the newest bundle onto node03, the warm standby.

If node02 is healthy but its etcd data is damaged, restore a local
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
| `minecraft/nightly/minecraft-<UTC time>.tar.age` | the Minecraft dashboard's store (`/bigdisk/k8s-cluster/minecraft`: its backups, snapshots and state), and from `/k8s-dynamic/stable` the live worlds' volumes (`minecraft/`) and the deleted worlds (`archived-minecraft/`) | every night; the newest `offsite_backup.minecraft.keep` (7) are kept |
| `minecraft/archive/minecraft-archive-<fingerprint>.tar.age` | the world archive (`/bigdisk/minecraft-archive`) | once; again only if its files change (the fingerprint hashes their names and sizes) |

A backup is uploaded when no file of its name is on Drive yet, so each goes
up once. Skipped: dotfiles, files written in the last 10 minutes, and
`offsite_backup.backups.exclude`, the files rewritten in place each night
(`etcd/LATEST` and the undated `sealed-secrets-keys.yaml.age`, whose dated
copies are uploaded).

**Not** copied off site:

- the live scrap data volume (`scrap-data-nfs`, with the database's Litestream
  replica): only scrap's backup runs are, so up to a day of pages can be lost
  with the NAS;
- any other `nfs-stable` or `nfs-rwx` volume (today the Minecraft worlds
  are the only dynamic NFS claims);
- the `local-nvme` PVs themselves (only the Grafana and Jellyfin backups made
  from them); Prometheus is not backed up at all;
- the Cloudflare OpenTofu state and its passphrase, and the admin passwords;
- the media library (`/bigdisk/media`) and anything else on the NAS outside
  the paths above.

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
    pruning off. The `scrap` and `backups` containers prune their own parts
    of `backups/` (the `run_dirs`, and the rest) separately: a container
    with any error (an unreadable folder, a failed upload, a failed listing)
    prunes nothing, and an empty `backups/` (a missing mount, or a wiped
    NAS) stops it before it uploads or prunes anything.
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
folder at once could split the backups between them. Then three containers
run side by side, because the NAS squashes root and no one user can read
everything:

- `backups` runs as `nobody` (65534), which owns the root-written etcd
  bundles, and uploads everything under `backups/` but the `run_dirs`;
- `scrap` runs as scrap's uid and gid (`offsite_backup.scrap.uid` / `gid`,
  10001), which own the files of its backup runs (many mode 0600, readable
  by no group), and uploads only the `run_dirs`;
- `minecraft` runs as uid 1000, which owns the worlds.

`backups` and `scrap` share `backups/` on Drive but each lists, cleans up and
prunes only its own part of it (the `run_dirs` folders, or the rest), so
neither takes the other's files for orphans. Any container failing fails the
Job, which is retried once; a retry uploads only the backups still missing,
and skips the Minecraft nightly if one from the same
UTC day is already on Drive. The first run uploads several GB and may take hours; a run
stopped by `deadline_hours` is carried on by the next one.

### Space on Drive

In the steady state the folder holds:

- every backup now on the NAS, plus each one deleted from the NAS in the
  last `prune_days`: about `prune_days` times the NAS's new backups per day;
- `keep` nightly Minecraft tarballs, each about the size of the store and
  the worlds;
- one archive tarball (more if the archive changes).

With about 240 MB of new backups a day (etcd 50 MB, Jellyfin
70 MB, scrap 120 MB), a 3.6 GB Minecraft tarball and a 5.8 GB archive, the
defaults come to about 43 + 25 + 6 = 75 GB. A free 15 GB Google account
would need less: lower `prune_days` (30 gives about 7 GB of backups) and
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

All three are pushed to the phone through ntfy, like the etcd backup
alerts ({doc}`/how-to/monitoring`).

### Set it up

This is done, and `offsite_backup.enabled` is `true`; the steps are kept
for a new Google account or OAuth client. They need a Google account with
space for the backups (see above), and the age key pair of the etcd backup
({ref}`etcd-offsite-backup`).

1. **Create an OAuth client** in the [Google Cloud console](https://console.cloud.google.com/):
   1. Create a project (any name, e.g. `home-cluster-backup`) and enable
      the **Google Drive API** in it.
   2. Under **Google Auth Platform**, configure the consent screen as
      **External**, add the account's address as a test user, and then **publish
      the app to production**. A consent screen left in *Testing* issues
      refresh tokens that expire after 7 days. An unverified app is fine
      for one's own account: Google warns once, then continues.
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
   `offsite_backup.age_recipient` is the age public key. Open a PR and
   merge it.
4. **Run it once now**, rather than waiting for the night (it refuses while
   a run is going):

   ```bash
   just offsite-backup-now
   ```

   Then look in the Drive for the `home-cluster-offsite` folder, and prove
   that a file from it decrypts (see below).

rclone refreshes its access token itself; the refresh token in the Secret
does not change. Re-run step 2 (and commit) if Google revokes it, for
example after a password change, or if you rotate the client secret.

A rebuild needs no new consent. A planned rebuild exports the sealed
`rclone.conf` with the other external credentials
(`OFFSITE_BACKUP_RCLONE_CONF_B64` in `.env`, from
`scripts/export-external-creds`) and reseals it against the new key with
the rest ({doc}`/how-to/manage-sealed-secrets`). After a cluster that died, restoring
the old sealing keys ({ref}`sealed-secrets-key-backup`) makes the
SealedSecret in Git decrypt as it is.

### Restore from Drive

Download what you need, either from the Drive web page (a folder downloads
as a zip) or with rclone, on any machine with the rclone config (the
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
instead: {doc}`/how-to/recover-control-plane`.

To rebuild the cluster from scratch (the full walk-through is
{doc}`/tutorials/build-the-cluster`; a planned rebuild of the running
cluster is {doc}`/how-to/reflash-rebuild`):

1. If the NAS was lost too, run the NAS setup again
   ({doc}`/how-to/nas-setup`), so that `/bigdisk/k8s-cluster` and
   `/k8s-dynamic/stable` exist, and unpack its data from Drive before
   going on ({ref}`restore-after-nas-loss`): the setup makes empty
   directories. scrap's restore from the unpacked run comes later, after
   step 6. Otherwise leave the NAS alone.
2. Check the inventory and variables (`hosts.yml`, `group_vars/all.yml`).
3. Flash and provision the nodes and install the cluster:
   `ansible-playbook pb_all.yml -e do_flash=true`. `do_flash` refuses to
   wipe an RK1's NVMe that has a partition table; only `flash_force` does,
   and on node04 that loses the Grafana and Prometheus local PV data
   ({doc}`/how-to/reflash-rebuild`).
4. Restore the sealed-secrets keys if the old cluster died
   ({ref}`sealed-secrets-key-backup`). A planned rebuild reseals instead;
   re-export your offline key copy afterwards.
5. Re-create the `admin-auth` Secret with `just set-admin-password`
   ({doc}`/tutorials/build-the-cluster`).
   The off-site backup's Drive credentials need nothing: the restored keys
   decrypt its SealedSecret, and a planned rebuild reseals it from `.env`
   ({ref}`offsite-backup`).
6. ArgoCD auto-syncs all services from Git. After a lost NAS, now
   restore scrap from the run unpacked in step 1
   ({ref}`restore-after-nas-loss`).
7. Restore the data of each `local-nvme` PV that was wiped, from the
   latest backup under `/bigdisk/k8s-cluster/backups/` on the NAS, using
   the restore recipes above. A PV is wiped by `wipe_local_data=true` on
   decommission (every node), by `flash_force` on its RK1 (node04: Grafana
   and Prometheus), and by a replaced disk (on nuc2: Jellyfin and scrap's
   off-NAS copy). So after a `flash_force` of node04, restore
   Grafana even though `wipe_local_data` was not used; Prometheus has no
   backup and starts empty. A PV that was not wiped still holds its data
   and re-binds automatically. scrap's static NFS volumes re-bind too, and
   its pod restores the database from the replica.

The services are back within minutes of the playbook finishing. Data needs
an explicit restore in two cases only: a wiped local PV (step 7) and a lost
NAS (steps 1 and 6).

(restore-after-nas-loss)=
### After losing the NAS

The nodes' `local-nvme` data is untouched, so Grafana, Jellyfin and
Prometheus lose nothing, and their next backups refill `backups/`. What was
only on the NAS does not come back by itself: scrap's live data, and the
Minecraft store, worlds and archive. Once the NAS setup has made the
directories, put these back from Drive ({ref}`offsite-backup`: download and
decrypt as in "Restore from Drive"). In a full rebuild, unpack them before
installing the cluster.

- **scrap.** This has two parts. First unpack the newest run
  (`backups/scrap/<run>.tar.age` on Drive) in
  `/bigdisk/k8s-cluster/backups/`, not in `backups/scrap/`: the tarball's
  paths start `scrap/<run>/` (a monthly run's start
  `scrap/monthly/<run>/`). The files must be owned by `10001:10001`. This
  can be done before the cluster is installed. Then, with the cluster
  running and ArgoCD synced, follow "Restore scrap" above: it is staged
  and needs scrap's volumes and a pod. The run on nuc2 (the
  `scrap-backup-copy` claim) needs no download and is normally the same
  run as the newest on Drive: if nuc2 survived, skip the unpack and
  restore from it instead. Until the restore, scrap refuses to start on an
  empty `scrap-data` beside existing backups, rather than start empty.
  Pages written since that run are lost.
- **Minecraft.** The newest `minecraft/nightly/minecraft-<time>.tar.age`
  holds `store/` (the contents of `/bigdisk/k8s-cluster/minecraft`) and
  `stable/minecraft/` and `stable/archived-minecraft/` (the folders of
  those names in `/k8s-dynamic/stable`). The newest
  `minecraft/archive/minecraft-archive-<fingerprint>.tar.age` holds
  `archive/` (the contents of `/bigdisk/minecraft-archive`). There is one
  for each state the archive has had, and a state that comes back is not
  uploaded again, so the last upload is the current archive unless the
  archive was changed back to an earlier state (files removed again, or
  restored to an earlier size). If it may have been, list the candidates
  (`age -d -i <key> <file> | tar -tv`) and take the one whose files and
  sizes are the archive you had. Unpack each into its place. The store and the worlds must be owned by `1000:1000`.
  Make the archive read-only again with `chmod -R a-w`
  ({ref}`minecraft-nas-directories`). The dashboard re-creates the
  worlds from the registry in its store once, at its start: if it is
  already running, restart it afterwards
  (`kubectl -n minecraft rollout restart deploy/minecraft-dashboard`).
  Changes in the worlds since that tarball are lost.
- **The other backups.** Normally nothing else needs to go back: the etcd
  bundles, sealed-secrets key exports and the Grafana and Jellyfin tarballs
  stay on Drive, and the nightly jobs write new ones to the NAS. The
  exception is a `local-nvme` PV that was wiped as well (step 7 above, for
  example Grafana after a `flash_force` of node04): step 7 looks for its
  backup on the NAS, so first download and decrypt that app's newest
  tarball from Drive into `/bigdisk/k8s-cluster/backups/<app>/`.

### Minecraft worlds after a rebuild

With the NAS intact, Minecraft worlds need no restore: their `nfs-stable`
folders on the NAS depend only on the PVC's namespace and name, so the dashboard re-creates its
worlds with their ports and settings, and their PVCs bind to their old data.
Every world is on `nfs-stable` ({doc}`/how-to/nfs-stable-paths`). Any other
claim on `nfs-stable`, the default class, also comes back with its data. `nfs-rwx` volumes come back empty, in new
folders.
