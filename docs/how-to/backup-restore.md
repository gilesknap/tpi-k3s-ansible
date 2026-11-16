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

`ssh nas` on this page means the NAS's `ansible` account, which has
`sudo`: `ssh ansible@192.168.1.3`, or a `Host nas` entry in `~/.ssh/config`
with that `HostName` and `User`. Paths on the NAS are the same as the
paths NFS clients mount ({doc}`/how-to/nas-setup`). The etcd bundles and
key exports are `0600` to `65534` (the root-squashed uid that writes them),
so reading them on the NAS needs `sudo`.

The backups on the NAS, and the Minecraft data, also go off site: a nightly
job copies them, age-encrypted, to Google Drive. Not everything in the table
does; {ref}`offsite-backup` lists what does and does not. A second job
copies the NAS backups to a Backblaze B2 bucket that nothing, not even a
compromised cluster, can delete from for 30 days ({ref}`offsite-b2`).

## Nightly timetable

| When | What | Runs as |
|------|------|---------|
| 23:15 Europe/London | etcd bundle and sealed-secrets keys | `k3s-etcd-backup.timer` on node02 |
| 00:30 Europe/London (monthly: the 1st, 00:40) | scrap | CronJobs `scrap-backup`, `scrap-backup-monthly` in `scrap` |
| 00:35 Europe/London (weekly: Sunday 00:40) | Grafana | CronJobs `grafana-daily`, `grafana-weekly` in `backups`, on node04 |
| 00:50 Europe/London | scrap's newest run, copied off the NAS | CronJob `scrap-backup-copy` in `scrap`, on nuc2 |
| 01:45 Europe/London (weekly: Sunday 01:50) | Jellyfin | CronJobs `jellyfin-daily`, `jellyfin-weekly` in `backups`, on nuc2 |
| 05:30 Europe/London | the backups on the NAS and the Minecraft data, to Google Drive | CronJob `offsite-backup` in `backups` |
| 05:45 Europe/London | the backups on the NAS, to Backblaze B2 | CronJob `offsite-backup-b2` in `backups` |

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
ssh nas 'ls -lh /bigdisk/k8s-cluster/backups/grafana/'
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
           # A copy from Drive: /bigdisk/k8s-cluster/restore-scratch/grafana
           path: /bigdisk/k8s-cluster/backups/grafana
           readOnly: true
   ```

   To restore a tarball brought back from Drive, unpack it in the restore
   scratch folder ({ref}`restore-scratch`), not in `backups/grafana`, and
   set the `backup` volume's `path` to
   `/bigdisk/k8s-cluster/restore-scratch/grafana`.

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

   For a run brought back from Drive, unpack it in the restore scratch
   folder ({ref}`restore-scratch`), not in `backups/scrap`, and replace the
   `backups` volume with one that mounts that folder from the NAS. The
   tarball's paths start `scrap/<run>/` (a monthly run's
   `scrap/monthly/<run>/`), so the restore's argument stays
   `/backups/<run>` (or `/backups/monthly/<run>`):

   ```yaml
       - name: backups
         nfs:
           server: 192.168.1.3   # nfs.server
           path: /bigdisk/k8s-cluster/restore-scratch/scrap
           readOnly: true
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
NAS_DIR=/bigdisk/k8s-cluster/backups/etcd
for f in sealed-secrets-keys.yaml.age sealed-secrets-keys.yaml.age.sha256; do
  ssh nas sudo cat "$NAS_DIR/$f" > "$f"
done
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

(unseal-check)=
### Check the keys open the SealedSecrets

`scripts/unseal-check` (`just unseal-check`) proves that the key export in
the off-site copy still opens the SealedSecrets in Git, as it would have to
after the cluster died. It is read-only. It:

1. downloads the newest dated export,
   `backups/etcd/sealed-secrets-keys/sealed-secrets-keys-<UTC time>.yaml.age`,
   and its `.sha256.age` sidecar, from Drive or, with `--target b2`, from B2;
2. checks the sidecar and decrypts the export with the backup age key;
3. runs `kubeseal --recovery-unseal` on one SealedSecret
   (`grafana-oauth-secret` by default; `--all` takes every one under
   `kubernetes-services/`);
4. prints each Secret's key names, never a value, and checks that every
   name the SealedSecret gives (`encryptedData`, and `template.data` if
   any) is there.

The downloads, the decrypted keys and a pasted age key are kept in
`/dev/shm` and deleted on exit; without a writable `/dev/shm` it refuses
to run. The unsealed Secret goes through a pipe
and is never stored. kubeseal runs with `KUBECONFIG` set to a path that
does not exist, so it never talks to a cluster. The result is in
`build/restore-test/unseal-check-last-run.txt`.

The only thing it reads from the cluster is rclone's config, from the
`offsite-backup-rclone` Secret (`offsite-backup-b2` for B2). With the cluster
dead, give it the config, or an export you already hold:

```bash
# With the cluster up:
just unseal-check
just unseal-check --target b2 --all
# Without the cluster: rclone's config ("rclone without the cluster")
# and the age key from files in /dev/shm.
just unseal-check --rclone-config /dev/shm/rclone.conf --identity /dev/shm/age.key
# Without rclone either: your offline copy of the keys.
just unseal-check --keys ~/sealed-secrets-keys-<date>.yaml.age
```

When everything passes but the newest export is over 48 hours old
(`--max-age-hours`), it says `WARN` and exits with status 3: the nightly
etcd backup or the off-site job has stopped. A FAIL (status 1) with
`no key could decrypt secret` means the export no longer matches the
SealedSecrets in Git, for example after a rebuild whose new key has not
reached the off-site copy yet. Run `just etcd-backup-now`, then
`just offsite-backup-now` for Drive and `just offsite-backup-now b2` for
B2.

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

3. Make sure `backups/etcd/` (with `pre-upgrade/`) exists on the NAS,
   owned by `65534`: the `nas` role creates it ({doc}`/how-to/nas-setup`).
   To check, and create it if missing:

   ```bash
   ssh nas ls -ldn /bigdisk/k8s-cluster/backups/etcd/pre-upgrade
   ansible-playbook pb_nas.yml --tags nas_datasets
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
ssh nas sudo cat /bigdisk/k8s-cluster/backups/etcd/LATEST
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
| `minecraft/archive/CURRENT.age` | the name of the archive copy that matched the NAS on the last successful check, and that check's time (UTC) | every night the archive check succeeds; a failed upload leaves the previous one |

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
  the off-site copy, but could delete it. The B2 copy
  ({ref}`offsite-b2`) is the one they cannot delete.
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
from kube-state-metrics' CronJob and Job series, so nothing fires while a
CronJob is disabled. Each alert is per CronJob: its `cronjob` label is
`offsite-backup` (Drive) or `offsite-backup-b2` (B2), so a failure on one
target shows as that target's:

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
as a zip) or with rclone, on any machine with an rclone config holding the
`[drive]` remote ({ref}`offsite-rclone-without-cluster` makes one without
the cluster):

```bash
rclone --config /dev/shm/rclone.conf lsf -R drive:home-cluster-offsite/backups/grafana
rclone --config /dev/shm/rclone.conf copy drive:home-cluster-offsite/backups/grafana/<file>.tar.gz.age .
```

Then decrypt with the private key, and verify or unpack:

```bash
age -d -i ~/k3s-etcd-backup.agekey <file>.tar.gz.age > <file>.tar.gz
age -d -i ~/k3s-etcd-backup.agekey <run>.tar.age | tar -x      # a scrap run
age -d -i ~/k3s-etcd-backup.agekey minecraft-<time>.tar.age | tar -t | head
```

The etcd bundles and sealed-secrets key exports are as they were on the NAS
(`.tar.age`, `.yaml.age`): restore them as in the sections above. To
restore Grafana or scrap from a copy from Drive, unpack it in the restore
scratch folder ({ref}`restore-scratch`) and point the recipe's volume
there, as its notes say.

(offsite-rclone-without-cluster)=
#### rclone without the cluster

The remote lives in the SealedSecret `offsite-backup-rclone` (namespace
`backups`), which only the running cluster can decrypt. Without it, make
the config in RAM-backed `/dev/shm` (so it is never written to disk) on
any machine with rclone (the devcontainer has it), in one of two ways:

- **From `.env`.** `just export-external-creds` saves it in `.env` as
  `OFFSITE_BACKUP_RCLONE_CONF_B64` (a planned rebuild does that first).
  If that `.env` is still there:

  ```bash
  (umask 077; grep '^OFFSITE_BACKUP_RCLONE_CONF_B64=' .env | cut -d= -f2- |
      base64 -d >/dev/shm/rclone.conf)
  ```

- **A new token from the same OAuth client.** With the `drive.file`
  scope, rclone sees only the files made through its OAuth client, so use
  that client: its `client_secret_<...>.json` from step 1 of "Set it up",
  kept offline. If the JSON is lost, open the same client in the Google
  Cloud console and add a new secret to it rather than making a new
  client. Then run

  ```bash
  (umask 077; rclone config --config /dev/shm/rclone.conf)
  ```

  and answer: `n` (new remote); name `drive`; storage `drive`;
  `client_id` and `client_secret` from the JSON, pasted at their prompts
  (so they are on no command line); scope `drive.file`; no service account
  file; no advanced config; `y` to use a web browser, and allow access in
  it; not a shared drive; `y` to keep the remote; then `q`. As in "Set it up", the browser must be
  on the same machine, or have port 53682 forwarded to it.

Without either, the Drive web page still downloads the files with just the
Google login. Delete `/dev/shm/rclone.conf` when done.

(offsite-restore-test)=
#### Test a restore

`scripts/restore-test` (`just restore-test`) proves the off-site copy can
be restored, without changing anything on Drive, the NAS or the cluster.
It downloads the newest scrap daily run, Grafana and Jellyfin daily
tarballs, etcd bundle with its `.sha256` sidecar, and the Minecraft
archive's `CURRENT` marker into a new scratch directory; decrypts each;
checks the SQLite databases (`PRAGMA integrity_check`), scrap's file
hashes and `COMPLETE` marker, the etcd bundle against its `MANIFEST`, and
that `CURRENT` names a copy on Drive; prints a PASS/FAIL table; and deletes
everything it downloaded or decrypted. Only the table is kept, in
`build/restore-test/last-run.txt`. The decrypted data sits in the scratch
directory (under `$TMPDIR` or `/tmp`, so on disk unless that is RAM-backed;
`--work-dir` moves it) until the script exits, and a killed run leaves a
`restore-test.*` folder there to delete by hand. It asks for the age private key (not
echoed) unless given `--identity`.

```bash
# With the cluster up: rclone's config comes from the Secret.
just restore-test
# Without the cluster: rclone's config and the age key from local files,
# both only read.
just restore-test --rclone-config /dev/shm/rclone.conf --identity /dev/shm/age.key
```

`--with-minecraft` also streams the newest Minecraft nightly (about
3.7 GB) through `age` and `tar -t`, writing nothing; `--no-decrypt` stops
after the downloads, with no key; `--help` lists the rest. To put the key
from paper into a file, type it into `(umask 077; cat >/dev/shm/age.key)`
and end with Ctrl-D; delete the file afterwards.

(restore-scratch)=
#### Where to unpack a copy from Drive

Unpack a backup brought back from Drive (for a drill, or because the NAS
copy is gone) in `restore-scratch/` at the root of the cluster share,
`/bigdisk/k8s-cluster/restore-scratch/<app>/` as NFS clients see it, and
never in `backups/`:

- `backups/` is the off-site job's source: a file put there is uploaded
  unless one of its name is already on Drive, and each app's retention
  prunes its folder. A copy there would be mixed in with the live backups.
- `restore-scratch/` is outside `backups/`, so the off-site job never
  reads it and no retention touches it.

Decrypt on the machine that holds the key and stream the result to the
NAS, so nothing decrypted is left on that machine:

```bash
S=/bigdisk/k8s-cluster/restore-scratch
ssh -t nas "sudo mkdir -p $S/grafana && sudo chown \$(id -u) $S $S/grafana"
# scrap: a run (unpacks as scrap/<run>/, owned by scrap's uid)
age -d -i ~/k3s-etcd-backup.agekey <run>.tar.age | ssh nas "cat >$S/run.tar"
ssh -t nas "cd $S && sudo tar -xf run.tar && sudo rm run.tar && sudo chown -R 10001:10001 scrap"
# Grafana: one tarball, readable by Grafana's uid
age -d -i ~/k3s-etcd-backup.agekey <file>.tar.gz.age | ssh nas "cat >$S/grafana/<file>.tar.gz"
ssh -t nas "sudo chown -R 472:472 $S/grafana"
```

Then follow "Restore — Grafana sqlite" or "Restore scrap" with the
`restore-scratch` volume their notes give. Once the restore is checked,
remove the folder: `ssh -t nas "sudo rm -rf ${S:?}"`.

(offsite-b2)=
## Second off-site copy: Backblaze B2

The Drive copy protects against a lost NAS, not against someone who takes
over the cluster. With root on a node, an attacker (or a compromised agent)
can read the Drive token from its Secret and delete everything the job
uploaded, and delete the NAS backups too. The second copy is the answer: the
`offsite-backup-b2` CronJob uploads the NAS backups to a
[Backblaze B2](https://www.backblaze.com/cloud-storage) bucket made with
**Object Lock in compliance mode**, with a default retention of 30 days.
Every version uploaded there is then immutable for 30 days: no application
key, not even the account owner's master key, can delete or overwrite it,
or shorten its retention, until the 30 days are up. {doc}`ADR 14 </explanations/decisions/0014-immutable-offsite-copy>`
records the decision.

It is the same job as the Drive one (the same scripts, the same age key,
the same names and layout under `backups/`, the same pruning rules), as a
second CronJob with its own Secret. It is off until the owner has done the
one-time setup below: `offsite_backup.b2.enabled` is `false`, and with it
off nothing is rendered.

### What goes to B2

Only the NAS `backups/` tree (`offsite_backup.b2.include: [backups]`):
scrap's runs, the Grafana and Jellyfin tarballs, the etcd bundles and the
sealed-secrets key exports. The Minecraft nightly tarball and the world
archive stay on Drive only; the archive has other copies. `include` takes
the same three entries as the Drive job's `offsite_backup.include`
(`backups`, `minecraft-nightly`, `minecraft-archive`), so either can be
added to B2 later.

### How it differs from Drive

- **Its key cannot touch the locks.** The application key in the
  `offsite-backup-b2` Secret is restricted to the one bucket, with only
  `listBuckets`, `listFiles`, `readFiles`, `writeFiles` and `deleteFiles`.
  It has none of `bypassGovernance`, `writeBucketRetentions`,
  `writeFileRetentions`, `writeFileLegalHolds`, `writeBuckets` or
  `deleteBuckets`, and no key capabilities. That is least privilege, not
  the protection itself: compliance mode is what stops a deletion, and it
  holds against a key with every capability.
- **Deleting only hides.** On B2 rclone's `deletefile` hides a file (the
  job never uses `--b2-hard-delete`; `RCLONE_B2_HARD_DELETE=false` is set
  in the CronJob and `hard_delete = false` in its config). The job's
  pruning keeps its Drive semantics: a hidden file is gone from the
  listing, and the bucket's lifecycle rule deletes the hidden version a day
  later, but only once its lock has expired. A prune touches only files
  uploaded over `prune_days` (180) ago, long past their lock, so pruning
  frees space as on Drive. An attacker's hide or overwrite, by contrast,
  leaves the locked version in place for the rest of its 30 days.
- **No temporary names.** On Drive a stream goes to a `.partial-` name and
  is renamed once complete. On B2 a rename is a copy, and the temporary
  version would be locked for 30 days too. So the stream goes straight to
  its final name, and rclone reads it through a fifo that the script holds
  open until the whole pipeline (tar, age) has finished: if anything
  failed, rclone is killed before it sees the end of the stream, so a
  cut-off upload never becomes a file. A large upload killed half-way is
  an unfinished large file, which the lifecycle rule cancels after a day.
- **No folders.** B2 has none, so there is no init container to make them.

**What the lock protects.** Retention runs from each version's upload, so
what is immutable at any moment is everything uploaded in the last 30 days.
As long as the job runs nightly, that includes the newest daily and weekly
backups. The newest monthly scrap run is the exception: it passes its 30
days a day or two before the next one is made, so for that while its lock
has expired (the daily scrap runs, all locked, hold newer data). An older file (a monthly scrap run from last year, say) is
past its lock, so the job's key could delete it. 30 days is far longer than
tampering would go unnoticed: a stopped or failing job raises
`OffsiteBackupStale` or `OffsiteBackupFailed` within 36 hours. The residual
risk is an attacker who silences both the job and the alerts and then waits
over 30 days; there is no external dead-man switch.

### Cost

B2 charges $6.95 per TB-month for storage (November 2026; check
[the pricing page](https://www.backblaze.com/cloud-storage/pricing)). The
first 10 GB are always free, uploads are free, downloads are free up to
three times what is stored, and the calls the job makes (uploads,
listings, hides: Class A, B and C) are free.

What the bucket holds, at the default `prune_days` of 180:

- the backups now on the NAS: about 3.3 GB (`backups/` today);
- each backup deleted from the NAS in the last 180 days. About 240 MB of new
  backups a day (etcd 50 MB, Jellyfin 70 MB, scrap 120 MB) means about
  240 MB a day leaving the NAS too: about 43 GB once the job has run for
  six months;
- the lock adds almost nothing: a pruned file is over 180 days old, long
  past its lock, so it goes a day after it is hidden. Only failed uploads
  and anything an attacker hid or overwrote stay the extra 30 days.

So about 3.3 GB at the start, growing by about 7 GB a month to about
46 GB after six months. That is free for about the first month, then
about (46 - 10) GB x $6.95/TB = $0.25 a month (about $3 a year) at the
steady state. That is the default, and worth it: deleted backups stay on
B2 as long as on Drive. To stay at about the free tier instead, set
`offsite_backup.b2.prune_days` to 30: the bucket then holds about
3.3 + 30 x 0.24 = 10.5 GB, just over the free 10 GB (about half a cent a
month), but keeps deleted backups for only 30 days on B2 (Drive still
keeps them for 180). Values under 30 save nothing, as every version is
kept for its 30 days anyway.

For comparison, the Minecraft data B2 does not get would cost more than all
of this: the archive is about 6 GB, and with the 30-day lock each nightly
tarball (about 3.6 GB) would be kept for 30 days, not 7: about 108 GB, so
about 114 GB with the archive, or about $0.80 a month.

### Set it up

The owner does this once. Have the age key pair of the other backups, and
the devcontainer (it has rclone, `curl`, `jq`, `yq` and `kubeseal`).

1. **Make a Backblaze account** for B2 Cloud Storage. Pick the region when
   signing up (EU Central suits a UK cluster; the price is the same), and
   turn on two-factor sign-in. The account's master application key is
   only for these steps: it never goes in the cluster.
2. **Install the B2 command-line tool** and sign in with the master key.
   In a devcontainer terminal:

   ```bash
   uv tool install b2
   b2 account authorize     # asks for the master keyID and key, not echoed
   ```

3. **Make the bucket**, private, with Object Lock enabled (it can only be
   turned on when the bucket is made), a default retention of compliance
   mode for 30 days, and a lifecycle rule that deletes hidden versions
   after a day and cancels unfinished large uploads after a day. Bucket
   names are global: pick one no one else has, e.g.
   `tpi-k3s-offsite-<something of your own>`:

   ```bash
   BUCKET=tpi-k3s-offsite-<something of your own>
   b2 bucket create --file-lock-enabled \
       --lifecycle-rule '{"fileNamePrefix": "", "daysFromUploadingToHiding": null, "daysFromHidingToDeleting": 1, "daysFromStartingToCancelingUnfinishedLargeFiles": 1}' \
       "$BUCKET" allPrivate
   b2 bucket update --default-retention-mode compliance \
       --default-retention-period "30 days" "$BUCKET"
   b2 bucket get "$BUCKET"
   ```

   The last command shows the settings: check `isFileLockEnabled` is
   `true`, the default retention is `compliance` for 30 days, and the
   lifecycle rule. The same is under **Buckets** in the web UI (Object
   Lock, Lifecycle Settings), where it can also be set by hand. These
   flags are those of the B2 CLI version 4; if one is refused, `b2 bucket
   create --help` gives its current name. Do not choose a longer retention
   on a whim: in compliance mode it cannot be shortened, and everything
   uploaded is paid for until it ends.
4. **Make the job's key**, restricted to the bucket, with only the five
   capabilities it needs:

   ```bash
   b2 key create --bucket "$BUCKET" offsite-backup-k3s \
       listBuckets,listFiles,readFiles,writeFiles,deleteFiles
   ```

   It prints the new keyID and application key, once: leave them on the
   screen for the next step. (The web UI's **Application Keys** page can
   restrict a key to the bucket too, but its access choices add
   capabilities the job must not have, which the next step refuses.)
5. **Seal it.** Put the bucket's name in `offsite_backup.b2.bucket` in
   `kubernetes-services/values.yaml` first, then:

   ```bash
   just seal-b2-offsite
   ```

   It asks for the keyID and the key (neither is echoed), checks with B2
   that the key is restricted to that bucket, has the five capabilities and
   nothing that writes retention, legal holds, buckets or keys, and that the
   bucket's lifecycle rule deletes hidden versions; then it seals a `[b2]`
   rclone remote into
   `kubernetes-services/additions/backups/templates/offsite-backup-b2-secret.yaml`.
   Nothing secret is printed or written to disk. Then sign the CLI out, so
   the master key is not left on disk: `b2 account clear`.
6. **Turn it on.** Set `offsite_backup.b2.enabled: true`, commit the sealed
   file and `values.yaml`, open a PR and merge it.
7. **Run it once now**, and prove a restore:

   ```bash
   just offsite-backup-now b2
   just restore-test --target b2
   ```

   The first run uploads the whole `backups/` tree (about 3.3 GB).

Optionally, under **Caps & Alerts** in the web UI, set an email alert on
storage, so a sudden growth (someone filling the bucket) is seen.

A rebuild keeps the key: `scripts/export-external-creds` exports it as
`OFFSITE_BACKUP_B2_RCLONE_CONF_B64` and the rebuild reseals it
({doc}`/how-to/manage-sealed-secrets`). To replace the key, make a new one
as in step 4, run step 5 again and commit, then delete the old key
(`b2 key delete <keyID>`, signed in with the master key).

(offsite-b2-restore)=
### Restore from B2

Make an rclone config with a `[b2]` remote in RAM-backed `/dev/shm`, in
one of these ways:

- **From `.env`**, if `just export-external-creds` has written it:

  ```bash
  (umask 077; grep '^OFFSITE_BACKUP_B2_RCLONE_CONF_B64=' .env | cut -d= -f2- |
      base64 -d >/dev/shm/rclone.conf)
  ```

- **A new read-only key**, which is safer anyway when the cluster may be
  compromised: sign in to the B2 web UI, **Application Keys**, **Add a New
  Application Key**, restricted to the bucket, **Read Only**. Then run
  `(umask 077; rclone config --config /dev/shm/rclone.conf)` and answer: `n`
  (new remote); name `b2`; storage `b2`; the keyID and key at their prompts;
  `hard_delete` false; no advanced config; `y`; then `q`.

The bucket holds `backups/` at its root, laid out as on Drive. The current
files:

```bash
rclone --config /dev/shm/rclone.conf lsf -R b2:<bucket>/backups/grafana
rclone --config /dev/shm/rclone.conf copy b2:<bucket>/backups/grafana/<file>.tar.gz.age .
```

Then decrypt and restore as in "Restore from Drive". The restore test
works the same way: `just restore-test --target b2` (add
`--rclone-config /dev/shm/rclone.conf --identity /dev/shm/age.key` without
the cluster).

**An older version.** B2 keeps every version for the 30 days of its lock,
including those hidden by pruning or by an attacker, and those overwritten.
Two rclone flags reach them:

- `--b2-version-at TIME` shows the bucket as it was at `TIME` (a date and
  time, e.g. `2026-11-10T00:00:00Z`, or an age, e.g. `7d`): every listing
  and copy then sees the files that were current then.

  ```bash
  rclone --config /dev/shm/rclone.conf --b2-version-at 2026-11-10T00:00:00Z \
      lsf -R b2:<bucket>/backups/scrap
  just restore-test --target b2 --at 2026-11-10T00:00:00Z
  ```

- `--b2-versions` lists every version, the older ones with their upload
  time put in the name before its last extension (`<run>.tar.age` becomes
  `<run>.tar-v2026-11-10-053012-000.age`); copy one by that name with the
  same flag.

(restore-after-attack)=
### After an attacker wiped Drive and the NAS

Someone with root on the cluster has deleted the Drive copy and the NAS
backups (and perhaps the live data). The B2 versions from the last 30
days are still there.

1. **Take the cluster's keys away**, from a machine outside the cluster:
   delete the B2 key in the web UI (**Application Keys**) and revoke the
   Drive token (the Google account's third-party access page). The
   attacker can then neither hide more on B2 nor fill the bucket. Hidden
   versions stay until their lock expires, so do not wait: the clock runs
   from each upload, and the newest backups have up to 30 days left.
   An rclone config made from the cluster's key (`.env`) stops working
   now: make one from a new read-only key, as in "Restore from B2" above,
   before the steps below.
2. **Find when it happened.** List with `--b2-versions` and with
   `--b2-version-at` at a few times, and pick a time before the first
   hide or overwrite, when the newest scrap run and etcd bundle were in
   place.
3. **Check that time's copy**:
   `just restore-test --target b2 --at <time> --rclone-config /dev/shm/rclone.conf --identity /dev/shm/age.key`.
4. **Rebuild** as in "Disaster recovery" below: rebuild the NAS directories
   and the nodes (a compromised cluster is rebuilt, not cleaned), and
   restore everything from B2 with `--b2-version-at <time>` in place of
   Drive. The sealing keys are in the etcd folder's dated exports
   (`backups/etcd/sealed-secrets-keys/`), so the SealedSecrets in Git
   decrypt again ({ref}`sealed-secrets-key-backup`). Then seal new
   credentials: a new B2 key (step 4 and 5 of "Set it up") and a new Drive
   token (`just seal-rclone-drive`), and rotate everything else the
   attacker could read.
5. **The Minecraft data** is not on B2: restore the worlds from what is
   left on Drive or the archive's other copies.

(restore-drills)=
## Restore drills

A backup counts only if it restores. Run these on a schedule, and write
down anything that breaks.

| When | What | How |
|------|------|-----|
| Monthly | List and decrypt-check both off-site copies, and open the SealedSecrets with the off-site keys | `just drill-monthly` |
| Quarterly | The monthly drill, plus a scrap restore from Drive into a throwaway pod | `just drill-monthly`, then "Quarterly: restore scrap into a throwaway pod" below |

`just drill-monthly` asks for the age private key once, or takes a key
file as its argument (`just drill-monthly /dev/shm/age.key`). Then it
runs, in turn:

- `scripts/restore-test --target drive` ({ref}`offsite-restore-test`);
- `scripts/restore-test --target b2` ({ref}`offsite-b2-restore`);
- `scripts/unseal-check --all` ({ref}`unseal-check`).

It needs the cluster up, since rclone's configs come from its Secrets.
restore-test decrypts about 1 GB of backups. The recipe puts that in
`/dev/shm` (`--work-dir`) when it has 2 GiB free. Otherwise it warns, and
the decrypted data goes to `$TMPDIR` or `/tmp`, on disk unless that is
RAM-backed, until each run ends. Each run's log is kept as `build/restore-test/drill-<UTC time>-<check>.txt`,
and one line per drill is added to `build/restore-test/drill-log.txt`:

```text
20261205T101500Z drive=PASS b2=PASS unseal=PASS
```

`unseal=WARN` means the keys opened every SealedSecret but the newest
export is over 48 hours old ({ref}`unseal-check`). The recipe exits 1 on
any FAIL, 3 on a WARN alone.

With the cluster dead, run the three scripts by hand with
`--rclone-config` and `--identity`, as in their sections.

### Quarterly: restore scrap into a throwaway pod

This proves a Drive run restores with `scrap restore`, without touching
the live scrap: the restore goes into an `emptyDir`, deleted with the pod.
A real restore over live scrap ("Restore scrap") is only for a planned
full drill or a `/rebuild-cluster`.

1. Run `just drill-monthly` first: its Drive log has the counts to compare
   against, from the same run.
2. Take the run the drill checked, named under "Selected (newest of
   each)" in its Drive log:

   ```bash
   grep '^  scrap ' build/restore-test/drill-<UTC time>-drive.txt
   # e.g.  scrap   backups/scrap/20261205T003000Z.tar.age   ...
   ```

   Download that file from Drive and unpack it in the restore scratch
   folder ({ref}`restore-scratch`), as
   `/bigdisk/k8s-cluster/restore-scratch/scrap/<run>/`.
3. Save this as `restore-drill.yaml`, with `<run>` and the image of the
   running scrap
   (`kubectl -n scrap get deploy scrap -o jsonpath='{.spec.template.spec.containers[0].image}'`):

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: scrap-restore-drill
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
         command: ["sh", "-c"]
         args:
           - |
             set -e
             # Into the empty /data ($SCRAP_DATA_DIR): no --stage, no --force.
             scrap restore /backups/<run>
             python - <<'PY'
             import sqlite3
             c = sqlite3.connect("file:/data/scrap.db?mode=ro", uri=True)
             q = lambda sql: c.execute(sql).fetchone()[0]
             print(f"pages={q('SELECT count(*) FROM page')} "
                   f"(live {q('SELECT count(*) FROM page WHERE deleted_at IS NULL')}), "
                   f"revisions={q('SELECT count(*) FROM page_rev')}")
             PY
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
         emptyDir: {}
       - name: backups
         nfs:
           server: 192.168.1.3   # nfs.server
           path: /bigdisk/k8s-cluster/restore-scratch/scrap
           readOnly: true
       - name: tmp
         emptyDir: {}
   ```

4. Run it and compare its last line with the drill's scrap row:

   ```bash
   kubectl apply -f restore-drill.yaml
   # Wait until it has finished, either way (prints Succeeded or Failed).
   until p=$(kubectl -n scrap get pod scrap-restore-drill -o jsonpath='{.status.phase}') &&
       [ "$p" = Succeeded ] || [ "$p" = Failed ]; do sleep 10; done; echo "$p"
   kubectl -n scrap logs pod/scrap-restore-drill | tail -n 1
   grep '^scrap ' build/restore-test/drill-<UTC time>-drive.txt
   ```

   The `pages=`, `(live ...)` and `revisions=` figures must be the same.
   The `emptyDir` is on the node's disk and needs room for the whole run,
   files included.
   If the pod fails, `kubectl -n scrap logs pod/scrap-restore-drill` gives
   scrap's reason.
5. Clean up: `kubectl -n scrap delete pod scrap-restore-drill`, then remove
   the scratch folder as in {ref}`restore-scratch`.

## Disaster recovery

If only the control plane is lost, restore it from the nightly etcd backup
instead: {doc}`/how-to/recover-control-plane`. If someone took over the
cluster and deleted the backups, start with {ref}`restore-after-attack`.

To rebuild the cluster from scratch (the full walk-through is
{doc}`/tutorials/build-the-cluster`; a planned rebuild of the running
cluster is {doc}`/how-to/reflash-rebuild`):

1. If the NAS was lost too, rebuild it ({doc}`/how-to/nas-ubuntu-zfs`):
   `pb_nas.yml` creates `/bigdisk/k8s-cluster`, its directories and
   `/k8s-dynamic/stable` ({doc}`/how-to/nas-setup`). Then unpack its data
   from Drive before going on ({ref}`restore-after-nas-loss`): the role
   makes empty directories. scrap's restore from the unpacked run comes later, after
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
Minecraft store, worlds and archive. Once `pb_nas.yml` has made the
directories ({doc}`/how-to/nas-ubuntu-zfs`; first try the NAS's own backup
pool, {ref}`nas-recovery`), put these back from Drive ({ref}`offsite-backup`: download and
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
  those names in `/k8s-dynamic/stable`). Each
  `minecraft/archive/minecraft-archive-<fingerprint>.tar.age` holds
  `archive/` (the contents of `/bigdisk/minecraft-archive`) in one of the
  states it has had. A state that comes back is not uploaded again, so the
  newest upload is not always the current one: read
  `minecraft/archive/CURRENT.age` (`age -d -i <key> CURRENT.age`), which
  names the copy that matched on the last successful nightly check and when
  that was, and restore that copy. Unpack each into its place. The store and the worlds must be owned by `1000:1000`.
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

(restore-minecraft-world)=
### Restore one Minecraft world from Drive

Use this when one world's folder is damaged or lost and the dashboard's own
snapshots and backups in its store cannot bring it back (if they can,
restore from the dashboard instead: its copies are taken with the world
stopped). Only Drive has the Minecraft data: B2 holds none.

The nightly tarball `minecraft/nightly/minecraft-<UTC time>.tar.age` holds
each live world as `stable/minecraft/<world>-data/`, the PVC's folder on
the NAS (`/k8s-dynamic/stable/minecraft/<world>-data` as NFS clients see
it). Drive keeps the newest seven. The tarball is taken while the worlds
run, so a world that was being saved at the time may need a second, older
tarball. Changes since the tarball are lost.

The steps below use `science-lab` as the world. They unpack into
`minecraft-restore-scratch/` in the stable share, beside `minecraft/`, not
into the cluster share's `restore-scratch/` ({ref}`restore-scratch`). On the
NAS, `k8s-dynamic` is a ZFS dataset of its own, so a move from the
cluster share would copy the whole world; from a folder on the same share,
the moves below are renames. The nightly tarball takes only `minecraft/` and
`archived-minecraft/` from that share, so it never uploads this folder.

1. **Stop the world** on the dashboard (<https://minecraft.gkcluster.org>,
   **Stop**). Check it has no pod:

   ```bash
   kubectl -n minecraft get deploy science-lab   # READY 0/0
   kubectl -n minecraft get pods | grep science-lab   # nothing
   ```

2. **Pick the tarball** (an rclone config with the `[drive]` remote:
   {ref}`offsite-rclone-without-cluster`, or the one the cluster uses):

   ```bash
   rclone --config /dev/shm/rclone.conf lsf drive:home-cluster-offsite/minecraft/nightly
   ```

3. **Unpack only that world** on the NAS. The tarball is streamed from
   Drive through `age` into `tar` on the NAS, so nothing decrypted is
   written on your machine. `tar` still reads the whole tarball (about
   3.7 GB):

   ```bash
   STABLE=/k8s-dynamic/stable
   S=$STABLE/minecraft-restore-scratch
   W=science-lab
   ssh -t nas "sudo mkdir -p $S && sudo chown \$(id -u) $S"
   rclone --config /dev/shm/rclone.conf cat \
       drive:home-cluster-offsite/minecraft/nightly/minecraft-<time>.tar.age |
     age -d -i ~/k3s-etcd-backup.agekey |
     ssh nas "tar -xf - -C $S stable/minecraft/$W-data"
   ssh nas "ls -l $S/stable/minecraft/$W-data/world/level.dat"
   ```

4. **Swap the contents** on the NAS. The world's folder stays where it is,
   with its own owner and mode (made by the NFS CSI driver); only what is
   inside it is replaced. The old contents are kept in `minecraft-restore-scratch/`
   until you are happy:

   If the world's folder itself is gone, make it first, with the owner and
   mode of another world's folder (here `animal-world-data`):

   ```bash
   ssh -t nas "cd $STABLE/minecraft && sudo mkdir $W-data &&
     sudo chown --reference=animal-world-data $W-data &&
     sudo chmod --reference=animal-world-data $W-data"
   ```

   Then swap:

   ```bash
   ssh -t nas "set -e; cd $STABLE
     sudo mkdir minecraft-restore-scratch/$W-before
     sudo find minecraft/$W-data -mindepth 1 -maxdepth 1 -exec mv {} minecraft-restore-scratch/$W-before/ \;
     sudo find minecraft-restore-scratch/stable/minecraft/$W-data -mindepth 1 -maxdepth 1 -exec mv {} minecraft/$W-data/ \;
     sudo find minecraft/$W-data -mindepth 1 -exec chown 1000:1000 {} +
     ls -ln minecraft/$W-data/world/level.dat"
   ```

   The world's files must be owned by `1000:1000` (the Minecraft server's
   uid and gid). The folder itself keeps the owner and mode it has.

5. **Start the world** on the dashboard (**Start**), follow its log
   (`kubectl -n minecraft logs -f deploy/science-lab`) until it is ready,
   and join it to check.

6. **Clean up** once the world is right: `ssh -t nas "sudo rm -rf ${S:?}"`.
   To go back instead, stop the world and swap `minecraft-restore-scratch/$W-before`
   back in the same way.
