# 14. A Second, Immutable Off-site Copy on Backblaze B2

**Status:** Accepted

## Context

Every backup lands on the NAS, and a nightly job copies it, age-encrypted, to Google Drive. The
Drive token has the `drive.file` scope, so it sees only the files it made, but it can delete them.
So can anything that holds it. The token is in a Secret in the `backups` namespace, and the NAS
backups are on a share the cluster mounts. Someone with root on the cluster, or a compromised agent
with cluster access, could read the token and delete the Drive copy and the NAS copies together.
The age encryption keeps them from reading the backups, not from destroying them. Until now that
was an accepted risk.

Making the Drive copy undeletable is not possible with a consumer Google account: the job's own
pruning needs delete rights, and Drive has no retention lock outside Google Workspace.

## Decision

Add a second off-site target: a Backblaze B2 bucket with Object Lock in **compliance mode** and a
default retention of **30 days**. Keep Drive as it is, as the first target.

- **The same job.** A second CronJob, `offsite-backup-b2`, runs the same scripts with the same age
  key, the same names and layout, and the same pruning. Each target is its own CronJob with its own
  Secret, so a failure on one alerts by its name and never stops the other's uploads.
- **Only the NAS backups.** A per-target `include` list picks what goes. B2 gets `backups/`; the
  Minecraft tarball and archive stay on Drive (the archive has other copies). That keeps B2 at
  tens of GB and a few dollars a year.
- **Compliance mode, 30 days.** No key, not even the account owner's master key, can delete or
  overwrite a locked version or shorten its retention. 30 days is far longer than tampering would go
  unnoticed: the `OffsiteBackupFailed` and `OffsiteBackupStale` alerts fire within 36 hours of a
  stopped or failing job. Longer would cost more for every upload and cannot be undone.
- **Pruning hides.** rclone's deletions on B2 hide files (`hard_delete` stays false), and a
  lifecycle rule deletes a hidden version a day after hiding, once its lock has expired. So the
  job's pruning frees space as on Drive, while any version uploaded in the last 30 days stays
  recoverable, whenever it was hidden or overwritten.
- **A narrow key.** The job's application key is restricted to the bucket, with `listBuckets`,
  `listFiles`, `readFiles`, `writeFiles` and `deleteFiles` only. `scripts/seal-b2-offsite` checks
  that with B2 before sealing it.
- **Off by default.** `offsite_backup.b2.enabled` is false until the owner has made the account,
  the bucket and the key.

## Consequences

- Someone who takes over the cluster can delete Drive and the NAS, but not the last 30 days of
  uploads on B2. Recovery reads the bucket as it was before the attack (`--b2-version-at`).
- What is immutable is what was uploaded in the last 30 days. Older files are past their lock and
  can be deleted with the job's key. An attacker who silences the job and the alerts and waits over
  30 days could still destroy everything; there is no external dead-man switch.
- The uploads skip the temporary `.partial-` name on B2 (a rename is a copy there, and the copy
  would be locked too), so the script holds the stream open until the pipeline's status is known.
- One more account, key and SealedSecret to keep; the rebuild exports and reseals the key with the
  other external credentials.
- Restores, and the restore test, can read either target (`just restore-test --target b2`).
