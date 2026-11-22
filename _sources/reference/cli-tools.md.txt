# Commands and tools

Everything that is typed to run this cluster: the `just` recipes, the Claude
Code commands and skills, the CLIs in the devcontainer, and the scripts that
no recipe wraps.

## Where a command can run

| Place | What it is | Limits |
|-------|-----------|--------|
| Devcontainer terminal | A VS Code terminal in this repo's devcontainer. It has the host's SSH agent, the kubeconfig and a TTY | None: every recipe works here |
| claude-sandbox | Where Claude Code runs, inside the devcontainer ({doc}`/explanations/architecture/claude-code`) | No SSH agent (it uses its own key), no TTY for prompts, cannot write `/etc`, cannot SSH to its own host (`ws03`) |
| Main checkout | `/workspaces/tpi-k3s-ansible` itself, not a git worktree | The Cloudflare state and `live.auto.tfvars` are gitignored and exist only here |

Run recipes from the repo root. Unless the table says otherwise, a recipe
works in either the devcontainer terminal or the sandbox.

## `just` recipes

`just --list` prints them. They are grouped here by what they are for, which
is not always the section of the `justfile` they sit in.

### Development and CI

| Recipe | What it does | Notes |
|--------|--------------|-------|
| `just setup` | Checks the forwarded SSH agent and logs `gh` in | Devcontainer terminal, once after the container is created ({doc}`/how-to/claude-code`) |
| `just check` | Checks the two age recipients match and that no Ansible destroys stored data, then runs `lint` and `docs` in parallel | Required before every push ({doc}`/how-to/work-in-branches`) |
| `just lint` | `ansible-lint` | Zero warnings; no `# noqa` |
| `just docs` | Builds these pages into `build/html`; any warning fails the build | |
| `just docs-watch` | Rebuilds and serves the pages on every change | |
| `just pre-commit` | Runs every pre-commit hook on all files | The hooks also run on `git commit` |

### Maintenance

| Recipe | What it does | Notes |
|--------|--------------|-------|
| `just status` | Nodes, ArgoCD apps, pods that are not Running, certificates that are not Ready | Read-only |
| `just switch-branch <branch>` | Points ArgoCD at a branch: `pb_all.yml --tags cluster -e repo_branch=<branch>` | {doc}`/how-to/work-in-branches` |
| `just argocd-sync` | Hard-refreshes every ArgoCD Application, so each re-fetches from Git | |
| `just hubble <args>` | Runs the `hubble` CLI against Hubble Relay through a port-forward (`localhost:4245`) that lasts for the command: `just hubble observe --last 20`, `just hubble status` | Every node's flows; `--last N` is per node |
| `just node-fence <node>` | Adds the `out-of-service` taint to a dead node so its pods restart elsewhere; refuses a Ready node | Only for a node that is powered off ({ref}`fence-a-dead-node`) |
| `just node-unfence <node>` | Removes the taint once the node is back | |
| `just upgrade-workstation <node> [args]` | Drains `ws03`, reinstalls its K3s agent at the control plane's version, uncordons it | Devcontainer terminal only: the sandbox cannot SSH to its own host ({doc}`/how-to/upgrade-k3s`) |
| `just restart-dex` | Restarts `argocd-dex-server`, `argocd-server` and `argocd-repo-server` | After a change to Dex's config or secrets ({doc}`/how-to/oauth-setup`) |
| `just headlamp-token` | Prints a 100 day token for the `headlamp` ServiceAccount, to paste into Headlamp's login page | The output is a credential |
| `just k3s-api-dns <ip>` | Points `k3s.lan` at a control plane address on the router (`dns_router`) and checks it resolves | Needs SSH to the router ({doc}`/how-to/recover-control-plane`) |
| `just restore-control-plane <snapshot> <token_file> [k3s_version] [node_password]` | Restores the control plane from a decrypted etcd bundle onto a fresh node. Asks for the node name to be typed; `DRY_RUN=1` previews | Devcontainer terminal ({doc}`/how-to/recover-control-plane`) |

### Cloudflare

All five wrap OpenTofu on the config in `cloudflare/`
({doc}`/how-to/cloudflare-as-code`). Run them in a devcontainer terminal, in
the main checkout: they prompt for a token or passphrase, and a worktree has
no state.

| Recipe | What it does | Credential |
|--------|--------------|------------|
| `just cf-init` | Downloads the provider and sets up the local, encrypted state | State passphrase |
| `just cf-plan [args]` | Shows what would change at Cloudflare | Read-only token |
| `just cf-apply [args]` | Applies the config; asks before changing anything | Edit token, always typed |
| `just cf-seal-tunnel-token` | Seals the tunnel token from the state into cloudflared's `SealedSecret`, without printing it | State passphrase; needs the running cluster |
| `just cf-env-tunnel-token` | Adds or replaces the `CLOUDFLARE_TUNNEL_TOKEN` line in `.env` from the state, without printing it or sealing it (creates `.env`, mode 600, if missing) | State passphrase; no cluster needed. For a build whose tunnel is new, before the `GENERATE_SECRETS=true` run |
| `just cf-tunnel-disconnect` | Cuts every tunnel connection, then lists the connectors that came back | Edit token; last step of a tunnel token rotation |

### Secrets and sealing

Each writes `SealedSecret` files under `kubernetes-services/additions/` to be
committed; none prints a secret unless the table says so
({doc}`/how-to/manage-sealed-secrets`).

| Recipe | What it does | Notes |
|--------|--------------|-------|
| `just seal-argocd-dex <target>` | Rotates one Dex-related secret: `github`, `argocd`, `monitor` or `grafana` | `github` prompts; follow with `just restart-dex` ({doc}`/how-to/oauth-setup`) |
| `just seal-ntfy [args]` | Seals ntfy's users and tokens, keeping the live values unless `--rotate <user>` | {doc}`/how-to/ntfy` |
| `just ntfy-tokens` | Prints the phone's and the VPS's ntfy tokens from the live Secret | Prints secrets: run it yourself in a devcontainer terminal, not through Claude |
| `just seal-rclone-drive <client_secret.json>` | Gets a Google Drive token through a browser consent and seals rclone's config for the off-site backup | Devcontainer terminal, with a browser on the same machine ({ref}`offsite-backup`) |
| `just seal-b2-offsite` | Asks for the Backblaze B2 key (not echoed), checks with B2 that it is restricted to the off-site bucket with only the capabilities the job needs, and seals it | Devcontainer terminal ({ref}`offsite-b2`) |
| `just set-admin-password` | Sets the `admin-auth` Secret that Grafana's built-in admin reads | Reads `ADMIN_PASSWORD` or prompts; writes to the cluster, not to Git |

### Backups

| Recipe | What it does | Notes |
|--------|--------------|-------|
| `just etcd-backup-now` | Starts the encrypted etcd backup on `node02` and shows its log and metrics | Over SSH ({ref}`etcd-offsite-backup`) |
| `just offsite-backup-now [drive\|b2]` | Starts the off-site backup to Google Drive (default) or Backblaze B2 as a one-off Job and follows its logs; refuses if one of that target is already running | {ref}`offsite-backup`, {ref}`offsite-b2` |

### Bootstrap and rebuild

Used when the cluster is built or rebuilt
({doc}`/tutorials/build-the-cluster`, {doc}`/how-to/reflash-rebuild`).

| Recipe | What it does | Notes |
|--------|--------------|-------|
| `just export-external-creds` | Writes the credentials a rebuild cannot regenerate (GitHub OAuth, Cloudflare, VPS relay, scrap, ntfy tokens, the Drive token) from the live Secrets into `.env` | `.env` is gitignored; do this before a decommission |
| `just generate-and-seal-all [output_dir]` | Generates every secret, seals them all and sets the admin password | Needs the `.env` variables exported ({doc}`/reference/variables`) |
| `just seal-from-json <json_file>` | Seals every cluster secret from the JSON that `scripts/generate-secrets` writes | The second step of the recipe above |
| `just gpu-setup` | Re-runs `--tags servers` on the NVIDIA node and restarts the device plugin pods | After a K3s reinstall on `ws03`; devcontainer terminal |
| `just vps-relay-forwards` | Prints `vps_relay.forwards` as `PROTO:PORTS` arguments for `scripts/vps-relay-setup` | {doc}`/how-to/vps-relay` |

### claude-sandbox

The sandbox's own helper, `claude-sandbox` (`gh-auth`, `glab-auth`, `update`,
`verify`, `version`), covers everything else; these two do what it cannot
({doc}`/how-to/claude-code`).

| Recipe | What it does | Notes |
|--------|--------------|-------|
| `just sandbox-conf` | Copies `.devcontainer/claude-sandbox.conf` to `/etc/claude-sandbox.conf` | Devcontainer terminal, outside the sandbox. Needed after every update of the sandbox by the claude-sandbox VS Code extension, whose installer restores the upstream file and drops the cluster's `allow-ip` entries |
| `just claude-ssh-bootstrap [deploy\|revoke]` | Creates Claude's own SSH key if it is missing and adds it to (or removes it from) the `ansible` account on every node: `pb_all.yml --tags claude_key` | Devcontainer terminal, outside the sandbox: the first run needs the host's SSH agent |

## Claude Code commands and skills

Both live in `.claude/` and are described in
{doc}`/explanations/architecture/claude-code`. A command is a procedure that
is started by name; a skill is background knowledge Claude loads when the
topic comes up.

| Command | What it does |
|---------|--------------|
| `/bootstrap-cluster` | Walks through a build from scratch: questions, configuration, secrets, playbooks, a credentials summary |
| `/rebuild-cluster` | Decommissions and rebuilds the cluster, keeping the NAS and local PV data; also the way to test a pull request that touches the rebuild path |
| `/add-node` | Adds a worker: inventory, playbooks, and the settings that depend on the node list |
| `/test-oauth-flow` | Checks in a browser that every service is reachable and its sign-in works, in a subagent |
| `/pr-squash` | Groups a branch's commits into tidy ones on a new branch and opens the pull request |

| Skill | What it knows |
|-------|---------------|
| `ansible` | Playbook structure, tags, topology rules, branch switching and the foot-guns |
| `argocd` | Repointing the branch, OCI Helm chart wiring, the `InvalidSpecError` cache bounce |
| `cloudflare` | The tunnel and Access configuration |
| `oauth` | oauth2-proxy and Dex setup and troubleshooting |
| `sealed-secrets` | Sealing and rotating, file naming for gitleaks, when a pod must be restarted after a reseal |

## Command-line tools in the devcontainer

The `tools` role (`pb_all.yml --tags tools`, run when the devcontainer is
created) downloads these into `$BIN_DIR` (`/root/bin`, a volume) and links
them into `/usr/local/bin`, with bash and zsh completions:

| Tool | Version | Used for |
|------|---------|----------|
| `kubectl` | The newest stable release when the role runs (not pinned) | Everything; `k` is an alias for it |
| `helm` | 3.20.0, with the `helm-diff` plugin | The `cluster` role's ArgoCD install; `helm template` when working on a chart |
| `kubeseal` | 0.35.0 | Sealing Secrets against the controller in `kube-system` |
| `hubble` | 1.20.4 (for Cilium 1.20.5) | `just hubble`: flows from every node through Hubble Relay |
| `argocd` | 3.3.2 | `argocd app list --core` and similar. `--core` uses the kube context's namespace, which must be set to `argo-cd` first (the kubeconfig's default is `default`) |

The role also writes the kubeconfig to `~/.kube/config`, fetched from the
control plane and pointed at `https://k3s.lan:6443`. It leaves the file alone
when the cluster and credentials in it have not changed.

The image (`.devcontainer/Dockerfile`) adds:

| Tool | Version | Used for |
|------|---------|----------|
| `tofu` (OpenTofu) | 1.13.2, checksum-pinned | The Cloudflare config (`just cf-*`) |
| `rclone` | 1.75.2, checksum-pinned | `scripts/seal-rclone-drive`; the same version as the off-site backup's image |
| `just`, `gh`, `jq` | From apt | Recipes, GitHub, JSON in the scripts |
| `yq` | The latest GitHub release when the image is built (not pinned) | YAML in the scripts (`seal-from-json`, `nfs-stable-paths`) |
| `htpasswd` (`apache2-utils`) | From apt | `scripts/set-admin-password` |
| `dig` (`dnsutils`) | From apt | DNS debugging |

Ansible, `ansible-lint` and Sphinx come from `pyproject.toml` through
`uv sync`, into a virtual environment on the `/cache` volume.

### Port-forward scripts

The `tools` role writes three scripts into `$BIN_DIR`. Each starts a
`kubectl port-forward` in the background, for when the Gateway is down or the
route through Cloudflare is the thing being debugged.

| Script | Forwards | Notes |
|--------|----------|-------|
| `grafana.sh` | `localhost:3000` to Grafana (`sts/grafana-prometheus` in `monitoring`) | Sign in as the built-in admin |
| `argo.sh` | `localhost:8080` to `argocd-server` in `argo-cd` | The GitHub sign-in redirects to `argocd.gkcluster.org`, so it does not complete on localhost |
| `dashboard.sh` | `localhost:4466` to Headlamp, and prints a 24 hour token for its login page | The port-forward skips oauth2-proxy |

## Scripts without a recipe

Most files in `scripts/` sit behind a recipe above. These do not:

| Script | What it does | Run it |
|--------|--------------|--------|
| `scripts/nfs-stable-paths` | Moves Minecraft world volumes from `nfs-rwx` to `nfs-stable` by a rename on the NAS. Dry run unless `--apply` | Devcontainer; every world has been moved, so it is kept for reference ({doc}`/how-to/nfs-stable-paths`) |
| `scripts/vps-relay-setup` | Installs or updates frps on the VPS as a Podman Quadlet, with `allowPorts` and the firewall set to the given forwards | On the VPS, as root, with the output of `just vps-relay-forwards` ({doc}`/how-to/vps-relay`) |
| `scripts/generate-secrets` | Generates every cluster secret into a JSON file, taking the external credentials from the environment | Normally through `just generate-and-seal-all` |
| `scripts/derive-argocd-client-secret` | Prints the Dex `argo-cd` client secret that ArgoCD derives from its `server.secretkey` | Called by the `cluster` role, `generate-secrets` and `seal-argocd-dex` |
| `scripts/check-age-recipient` | Fails if `etcd_backup_age_recipient` and `offsite_backup.age_recipient` differ | Called by `just check` and a pre-commit hook |
| `scripts/check-no-destroy` | Fails if any Ansible, or a script a role installs, runs a destructive storage command (`zfs destroy`, `zfs receive -F`, `wipefs`, `mkfs`, `dd` to a device, `rm -r` of a data path and the like; argv lists and shell blocks are read whole) or removes a data path with the file module, outside its short allowlist (the RK1 flash role, the opt-in wipe in `pb_decommission.yml`), if `zpool create` loses its opt-in gating in the `nas` role, or if a cluster playbook targets the NAS. It cannot see commands or paths built from variables at run time | Called by `just check` and a pre-commit hook |
| `scripts/test-check-no-destroy` | Runs `check-no-destroy` on a copy of the repo with each case it must catch added, and a few it must let through | Called by `just check` |
| `scripts/lib/` | Shared helpers: `seal.sh` (kubeseal wrapper), `cf-secrets.sh` (secret prompt), `ntfy_auth.py` (ntfy's users) | Sourced or imported, never run directly |
