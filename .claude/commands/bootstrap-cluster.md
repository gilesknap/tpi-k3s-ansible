# Bootstrap Cluster

Build this cluster from bare metal: the first build, or a rebuild after a
disaster that also re-flashes the RK1s. This command walks the user through
`docs/tutorials/build-the-cluster.md` step by step; read that page first and
follow it where this file is shorter. The cluster is the one described in the
repo (gkcluster.org): the three configuration files already describe it, so
this is not an interview about new hardware.

Use something else when:

- the machines already run Ubuntu and only K3s and the services need
  rebuilding: `/rebuild-cluster` (`docs/how-to/reflash-rebuild.md`);
- the *same* cluster (its etcd state and sealing key) is to come back from
  the encrypted backup: `docs/how-to/recover-control-plane.md`;
- one node is being added or re-flashed: `/add-node`,
  `docs/how-to/node-operations.md`, `docs/how-to/reflash-rebuild.md`.

## Rules

- Confirm with the user before each step that changes a machine (flash,
  playbook run, router DNS, `cf-apply`). Read-only checks need no
  confirmation.
- Never commit to `main`. The build runs on a branch (Phase 6) and the
  playbook commits and pushes the sealed secrets to it. Commit anything
  else only when the user says so.
- Never `kubectl apply/patch/edit/delete` ArgoCD-managed resources;
  `kubeseal` (inside `GENERATE_SECRETS=true`) and `just set-admin-password`
  are the sanctioned exceptions.
- Never print or copy a credential into the conversation. Values go into
  `.env` (gitignored) by script, or the user types them there.
- `-e do_flash=true` flashes the eMMC of every Turing Pi node that does not
  answer SSH. It never wipes an RK1 NVMe that has a partition table; that
  needs `-e flash_force=true`, which destroys the node's `/var/lib/k8s-data`
  (Grafana's and Prometheus's data on node04). Never pass `flash_force`
  without telling the user exactly what is lost and getting their go-ahead.
- Inside the claude-sandbox, add `--private-key
  /root/.config/claude-ssh/id_ed25519` to `ansible`/`ansible-playbook`, and
  `-i` the same key to `ssh`. Before the `claude_key` play has run on a
  freshly flashed node, only the ansible key (forwarded agent) works: hand
  those runs to the user as a script if the sandbox cannot reach the agent.

## Phase 1: Check what must exist first

Go through the "What must exist first" table in the tutorial with the user
and confirm each row. Most are by hand, outside the repo:

- the Turing Pi `turingpi` with the three RK1s and its SD card at
  `/mnt/sdcard`; `nuc1`, `nuc2` and `ws03` with Ubuntu installed by hand
  and a login that can `sudo`;
- the router's fixed DHCP leases and names;
- the NAS directories (`docs/how-to/nas-setup.md`);
- the Cloudflare zone with Zero Trust and its login methods
  (`docs/how-to/cloudflare-as-code.md`);
- the two GitHub OAuth apps (`docs/how-to/oauth-setup.md`);
- the Tailscale OAuth client and frps on the VPS (`docs/how-to/vps-relay.md`);
- the offline age key pair whose public half is
  `etcd_backup_age_recipient` in `group_vars/all.yml`.

Stop and point the user at the matching page for any that is missing.

## Phase 2: Prepare the workstation

From "Prepare the workstation" in the tutorial:

1. `pub_keys/ansible_rsa.pub` exists, and the private key is loaded in the
   host's `ssh-agent` (`ssh-add -l` in the devcontainer lists it).
2. `ssh root@turingpi true` works without a password. If not, the user
   copies the key to the BMC (`scp pub_keys/ansible_rsa.pub
   root@turingpi:.ssh/authorized_keys`) and sets a root password there.
3. `just setup` has been run in the devcontainer.

## Phase 3: Read the configuration

Read `hosts.yml`, `group_vars/all.yml` and `kubernetes-services/values.yaml`
and summarise them for the user: the nodes, `control_plane`,
`k3s_api_name`, `repo_remote`, the enabled services and the
`local_storage` / `k8s_data_dirs` pins. They are already right for this
cluster: change them only if the hardware has changed, and then keep the
two pairs that must agree in step (`admin_emails` in both files, and each
`local_storage` entry against its `k8s_data_dirs` entry). See
`docs/reference/inventory.md` and `docs/reference/variables.md`.

## Phase 4: API name and hand-installed nodes

1. Point the API name at the control plane on the router:

   ```bash
   just k3s-api-dns 192.168.1.82
   ```

2. Give `nuc1`, `nuc2` and `ws03` their `ansible` account (once per
   install; `-K` prompts for the login's sudo password, so the user runs
   it):

   ```bash
   ansible-playbook pb_add_nodes.yml -e ansible_user=<login> -K
   ```

## Phase 5: Collect the credentials

The table in "Collect the credentials" lists them; the first six are
required by `GENERATE_SECRETS=true`.

- **If the old cluster is still running**, read them all out of it into
  `.env`:

  ```bash
  just export-external-creds
  ```

- **Otherwise** the user fills `.env` from where each value was issued
  (their offline copy of `.env`, the OAuth apps, the Cloudflare token).
  `CLOUDFLARE_TUNNEL_TOKEN` comes from the OpenTofu state, so on a build
  where the tunnel does not exist yet, create the edge first
  (`just cf-init`, `just cf-plan`, `just cf-apply`) and then write the
  token into `.env` (added or updated, never printed; no cluster needed).
  Both run in the main checkout, where the OpenTofu state is, not in a git
  worktree:

  ```bash
  just cf-env-tunnel-token
  ```

Check every required name has a non-empty line in `.env` (names only, never
values) and remind the user to keep a copy of `.env` off the cluster.

## Phase 6: Run the playbook

Confirm with the user, check which nodes answer SSH (any that does not will
be flashed), then run on a build branch that ArgoCD tracks:

```bash
git checkout main && git pull
git checkout -b rebuild-$(date +%Y%m%d)
git push -u origin HEAD

set -a && source .env && set +a
GENERATE_SECRETS=true ansible-playbook pb_all.yml \
  -e do_flash=true -e repo_branch=$(git branch --show-current)
```

This is a long run (about 25 minutes per RK1 flashed, in turn, then the
K3s and cluster stages): hand it to a background agent and stay responsive.
The stages are `tools`, `flash`, `known_hosts`, `servers`, `k3s`, `cluster`
and `claude_key` (`docs/reference/playbook-tags.md`). If `claude_key` fails
because Claude's key does not exist yet, run `just claude-ssh-bootstrap`.

The admin password is printed in the output and saved to
`/tmp/cluster-secrets/admin-password.txt`; tell the user where it is, do not
repeat it.

## Phase 7: The Cloudflare edge

If the edge already existed (a rebuild), confirm nothing drifted:

```bash
just cf-init
just cf-plan      # expect "No changes"
```

If Phase 5 created it, the `GENERATE_SECRETS=true` run has already sealed
its token for cloudflared from `.env`; `just cf-plan` should now show no
changes.

## Phase 8: Verify

Work down the tutorial's "Verify" list, polling rather than waiting blind:

1. `kubectl get nodes -o wide`: six nodes `Ready`, node02
   `control-plane,etcd`.
2. `just status` and `kubectl get sealedsecrets -A`: every application
   `Synced`/`Healthy`, every SealedSecret decrypted. If one says
   `no key could decrypt secret`, run `just argocd-sync`, then
   `just restart-dex`.
3. `kubectl get certificate -A`: `wildcard-cert` `READY True`.
4. `kubectl get pv`: every PV `Bound`, including the `local-nvme` ones.
5. Logins: the user signs in at <https://home.gkcluster.org> to ArgoCD and
   Grafana; Headlamp takes a token from `just headlamp-token`.
6. Backups: `just etcd-backup-now` and `just offsite-backup-now`.
7. The user downloads one off-site file and decrypts it with the offline
   age key (`docs/how-to/backup-restore.md`).

## Phase 9: Merge

Prepare a pull request from the build branch for the user to merge, then
put the cluster back on `main` (`docs/how-to/work-in-branches.md`):

```bash
just switch-branch main
```

Finish with a short summary: what ran, what was flashed, anything that
failed or was skipped, and where the admin password is.
