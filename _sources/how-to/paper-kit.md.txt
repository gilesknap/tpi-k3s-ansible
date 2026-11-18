# Print the paper recovery kit

The paper recovery kit is a printed PDF for the worst case: the cluster,
the NAS and the workstation all lost at once. It holds what nothing else
can give back, starting with the one age private key that decrypts every
off-site backup ({doc}`/how-to/backup-restore`). Keep the printed copies
somewhere safe, at least one outside the house, and reprint it when
something on it changes.

## What is in it

| Pages | What |
|-------|------|
| First page | The age private key, as text in groups of five and as a QR code, with the public key it must match (`etcd_backup_age_recipient` in `group_vars/all.yml`), and where the printed copies are kept |
| Account recovery | Logins and recovery codes for Google (whose Drive holds the first off-site copy), GitHub, Cloudflare, Backblaze B2, Tailscale, the domain registrar, the VPS and the Anthropic console |
| Local passwords | The OpenWrt router, the Turing Pi BMC, the password manager and the Cloudflare OpenTofu state passphrase |
| SSH access | The SSH private key Ansible uses, as QR codes and as text, with its fingerprint and public key |
| Map and recovery order | What to recover first, where the off-site copies are, how to decrypt them, and the hosts and addresses (from `hosts.yml` and, when it answers, the cluster) |
| Appendix | Every cluster credential (the `.env` set `scripts/export-external-creds` exports, the ntfy tokens, both off-site rclone configs, the Tailscale OAuth client and the admin password), still age-encrypted to the same key, as QR codes and as text |

The first page opens everything, so the printed kit is as sensitive as all
the backups together: store it like cash, and never photograph it to a
cloud service.

## Where its data lives

The builder is `scripts/paper-kit/`. Its data is never in Git, not even
encrypted: it lives in `_claude/paper-kit-data/` at the root of the
checkout (gitignored), or in the directory `$PAPER_KIT_DATA` names. Run
from a Git worktree, the builder looks in the worktree's own `_claude/`, so
set `PAPER_KIT_DATA` to the main checkout's directory there.

| File | What | Written by |
|------|------|------------|
| `cluster-creds.age` | The appendix's credentials, age-armored to the cluster key | `just paper-kit-refresh` |
| `answers.age` | Everything typed into the form, age-armored to the cluster key | the builder, when "save my answers" is ticked |
| `kit.json` | Optional, plain JSON, nothing secret: private facts the PDF prints. `extra_drive_folders`, a list of `{"name": ..., "what": ...}`, adds Google Drive folders to the download step. | by hand |

`just paper-kit-refresh` creates the directory (mode `0700`) if it is missing; the builder
stops with an error naming it if it is missing. The cluster does not back
this directory up. Losing it loses nothing that matters: the credentials
come again from the cluster, and the answers are on the last printed kit.

## Reprint it

Run these in the repo's devcontainer, with `kubectl` pointed at the cluster
and `age` and `age-keygen` on the `PATH` (or in `~/bin`):

1. Refresh the credentials from the live cluster:

   ```bash
   just paper-kit-refresh
   ```

   It prints the names of the credentials it found and any it could not
   read, never their values. It refuses to run if the kit's public key no
   longer matches `etcd_backup_age_recipient`.

2. Make the PDF:

   ```bash
   just paper-kit
   ```

   It serves a form on `127.0.0.1` and prints its URL, which carries a
   one-time token (VS Code's port forwarding works). Unlock it with the
   cluster's age private key: the builder refuses any other key. Fields
   with a saved answer are left empty; leave them to keep the answer, type
   to replace it, or tick "clear saved value". The form warns when the
   credentials are over 30 days old. "Make the PDF" downloads it to the
   browser; nothing is written in the repo except `answers.age`.
   `just paper-kit --cli` asks the same questions in the terminal instead
   and writes the PDF (mode `0600`) to your home directory, or to the path
   given after `--cli`.

3. Print it, check every QR code scans with a phone (the key on the first
   page, the SSH key and each appendix code), then delete the PDF and
   empty the trash. Replace the old printed copies and destroy them.

Reprint after rotating any credential in the appendix (a reseal, a new
token, a new B2 key), after using or regenerating recovery codes, after
changing the SSH key or the age key, and when hosts change.

## Use it

The kit's own "Map and recovery order" page is the procedure. In short:
type the key from the first page into `key.txt` (`age-keygen -y key.txt`
must print the public key beside it), recover the Google account, download
the off-site copy from Drive (or B2), decrypt with
`age -d -i key.txt`, then follow {doc}`/how-to/backup-restore` from
"Disaster recovery". To get the credentials back, scan the appendix codes
in order into `creds.age`, decrypt it to `creds.json`, and turn it into
`.env` with the `jq` line printed beside them.
