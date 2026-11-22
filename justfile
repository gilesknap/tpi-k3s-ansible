################################################################################
# dev/CI — devcontainer setup, linting, docs
################################################################################

# First-time devcontainer setup: authenticate gh.
# (SSH keys + known_hosts come from the host via VS Code Dev Containers —
#  agent socket is forwarded and known_hosts is copied on attach.)
setup:
    scripts/setup

# Run all checks before committing (lint + docs in parallel)
check:
    scripts/check

# Run ansible-lint
lint:
    uv run ansible-lint

# Build Sphinx documentation
docs:
    uv run sphinx-build --fresh-env --show-traceback --fail-on-warning --keep-going docs build/html

# Auto-rebuild docs on change
docs-watch:
    uv run sphinx-autobuild --show-traceback --watch README.md docs build/html

# Run pre-commit hooks on all files
pre-commit:
    uv run pre-commit run --all-files --show-diff-on-failure

################################################################################
# maintenance — day-to-day cluster operations and rotation
################################################################################

# Quick cluster health check: nodes, ArgoCD apps, failing pods, certificates
status:
    scripts/status

# Switch the cluster to track a different git branch
switch-branch branch:
    ansible-playbook pb_all.yml --tags cluster -e repo_branch={{ branch }}

# Force ArgoCD to re-fetch from git and re-sync all applications
argocd-sync:
    scripts/argocd-sync

# Fence a dead node so its pods restart elsewhere (out-of-service taint).
# Refuses a Ready node; the node must be powered off.
node-fence node:
    scripts/node-fence fence {{ node }}

# Remove the fence once the node is back
node-unfence node:
    scripts/node-fence unfence {{ node }}

# Drain, reinstall and uncordon a workstation's k3s agent.
# Run in the project's devcontainer terminal, not on the host or in claude-sandbox.
upgrade-workstation node *args:
    scripts/upgrade-workstation {{ node }} {{ args }}

# Cloudflare config as code (cloudflare/, OpenTofu); see
# docs/how-to/cloudflare-as-code.md. Run in the devcontainer.
# Download the provider and set up the local, encrypted state
cf-init:
    scripts/cf-tofu init

# Show what would change at Cloudflare (read-only token)
cf-plan *args:
    scripts/cf-tofu plan {{ args }}

# Apply the Cloudflare config (edit token; asks before changing anything)
cf-apply *args:
    scripts/cf-tofu apply {{ args }}

# Seal the tunnel token from the tofu state into cloudflared's SealedSecret
# (after a cf-apply that rotated it; the token is never printed)
cf-seal-tunnel-token:
    scripts/cf-seal-tunnel-token

# Write the tunnel token from the OpenTofu state into .env without sealing
# it (first build: before a cluster exists; the token is never printed)
cf-env-tunnel-token:
    scripts/cf-seal-tunnel-token --env-only

# Force every tunnel connection to disconnect, then list the connectors
# (edit token; after a token rotation and cloudflared restart)
cf-tunnel-disconnect:
    scripts/cf-tunnel-disconnect

# Restart Dex and ArgoCD server (use after changing dex.config or secrets)
restart-dex:
    kubectl rollout restart deployment argocd-dex-server argocd-server argocd-repo-server -n argo-cd
    @echo "Restarted argocd-dex-server, argocd-server, argocd-repo-server"

# Generate a 100 day Headlamp ServiceAccount token (paste into the login page after OAuth)
headlamp-token:
    @kubectl create token headlamp -n headlamp --duration=2400h

# Rotate a single Dex-related secret in the live cluster. Subcommand required:
# github, argocd, monitor, grafana (see scripts/seal-argocd-dex help)
seal-argocd-dex target:
    scripts/seal-argocd-dex {{ target }}

# Seal ntfy's users and tokens, keeping live values (e.g. --rotate vps)
seal-ntfy *args:
    scripts/seal-ntfy {{ args }}

# Reseal scrap-secrets, keeping live values (--api-key, --canary new|revoke)
seal-scrap-secrets *args:
    scripts/seal-scrap-secrets {{ args }}

# Seal rclone's Google Drive token for the off-site backup (prints nothing secret)
seal-rclone-drive client_secret_json:
    scripts/seal-rclone-drive "{{ client_secret_json }}"

# Seal the Backblaze B2 key for the second off-site copy (asks for it; prints nothing secret)
seal-b2-offsite:
    scripts/seal-b2-offsite

# Run an off-site backup now and follow its logs: target drive (default) or b2
offsite-backup-now target="drive":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ target }}" in
        drive) cronjob=offsite-backup ;;
        b2) cronjob=offsite-backup-b2 ;;
        *) echo "target must be drive or b2" >&2; exit 2 ;;
    esac
    # Refuse while a run (scheduled or manual) of that target is going: two
    # runs at once would upload the same files twice.
    active=$(kubectl -n backups get jobs -l "app.kubernetes.io/name=$cronjob" -o json |
        jq -r '[.items[] | select((.status.active // 0) > 0) | .metadata.name] | join(" ")')
    if [ -n "$active" ]; then
        echo "An off-site backup is already running: $active" >&2
        echo "Follow it with: kubectl -n backups logs -f job/<name> --all-containers --prefix" >&2
        exit 1
    fi
    job=$cronjob-now-$(date +%s)
    kubectl -n backups create job --from="cronjob/$cronjob" "$job"
    kubectl -n backups logs -f "job/$job" --all-containers --prefix --pod-running-timeout=5m

# Downloads the newest of each backup, decrypts, checks and deletes it;
# --rclone-config and --identity work without the cluster (see --help).
# Read-only restore test of an off-site copy (Drive, or --target b2)
restore-test *args:
    scripts/restore-test {{ args }}

# kubeseal --recovery-unseal with no cluster; prints key names, never values.
# --rclone-config or --keys make it work with the cluster dead (see --help).
# Read-only check that the off-site sealing keys open the SealedSecrets in Git
unseal-check *args:
    scripts/unseal-check {{ args }}

# One age key for all three: pasted when asked, or a file as the argument
# (just drill-monthly /dev/shm/age.key). Adds a dated line to
# build/restore-test/drill-log.txt (docs/how-to/backup-restore.md,
# "Restore drills").
# Monthly drill: restore-test of Drive and B2, then unseal-check --all
drill-monthly identity="":
    #!/usr/bin/env bash
    set -uo pipefail
    dir=build/restore-test
    mkdir -p "$dir" || exit 1
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    id={{ quote(identity) }}
    # A relative path is the caller's, not the justfile's directory.
    case $id in "" | /*) ;; *) id={{ quote(invocation_directory()) }}/$id ;; esac
    key=
    trap '[ -n "$key" ] && rm -f "$key"' EXIT
    if [ -n "$id" ]; then
        [ -r "$id" ] || { echo "cannot read $id" >&2; exit 1; }
    else
        # Pasted once, never echoed, into RAM-backed tmp where there is one;
        # deleted on exit. Nothing runs if the file cannot be made.
        tmpdir=/dev/shm
        if [ ! -d "$tmpdir" ] || [ ! -w "$tmpdir" ]; then
            tmpdir=${TMPDIR:-/tmp}
            echo "warning: no writable /dev/shm; the key goes in $tmpdir" >&2
        fi
        key=$(umask 077; mktemp "$tmpdir/drill-age.XXXXXX") ||
            { echo "cannot make a key file in $tmpdir" >&2; exit 1; }
        printf 'Paste the age private key (AGE-SECRET-KEY-1...), then Enter: ' >/dev/tty
        IFS= read -rs k </dev/tty; echo >/dev/tty
        case $k in
            AGE-SECRET-KEY-1*) ;;
            *) unset k; echo "that is not an age private key" >&2; exit 1 ;;
        esac
        printf '%s\n' "$k" >"$key" || { unset k; echo "cannot write $key" >&2; exit 1; }
        unset k
        id=$key
    fi
    # restore-test's decrypted data in RAM when /dev/shm has room for it
    # (it needs about 1 GB; 2 GiB leaves a margin), else on disk.
    work=()
    avail=$(df --output=avail -k /dev/shm 2>/dev/null | tail -n 1 | tr -d ' ')
    if [ -w /dev/shm ] && [ "${avail:-0}" -ge 2097152 ]; then
        work=(--work-dir /dev/shm)
    else
        echo "warning: under 2 GiB free in /dev/shm; restore-test's decrypted data goes to" \
            "${TMPDIR:-/tmp}, on disk unless that is RAM-backed" >&2
    fi
    # Each run's output to the terminal; only PASS, WARN or FAIL captured.
    # Only unseal-check's 3 means WARN (all passed, newest key export stale).
    restore() { if scripts/restore-test "$@" >&2; then echo PASS; else echo FAIL; fi; }
    unseal() {
        scripts/unseal-check "$@" >&2
        case $? in 0) echo PASS ;; 3) echo WARN ;; *) echo FAIL ;; esac
    }
    drive=$(restore --target drive --identity "$id" "${work[@]}" \
        --log "$dir/drill-$stamp-drive.txt")
    b2=$(restore --target b2 --identity "$id" "${work[@]}" \
        --log "$dir/drill-$stamp-b2.txt")
    unseal=$(unseal --all --identity "$id" --log "$dir/drill-$stamp-unseal.txt")
    line="$stamp drive=$drive b2=$b2 unseal=$unseal"
    echo "$line" >>"$dir/drill-log.txt" ||
        { echo "$line"; echo "could not add that line to $dir/drill-log.txt" >&2; exit 1; }
    echo; echo "$line (logs: $dir/drill-$stamp-*.txt; history: $dir/drill-log.txt)"
    case "$drive $b2 $unseal" in *FAIL*) exit 1 ;; *WARN*) exit 3 ;; esac

# The paper disaster-recovery kit (docs/how-to/paper-kit.md). Its data is in
# _claude/paper-kit-data/ (gitignored), never in git. Prints names, never values.
# Refresh the paper kit's encrypted cluster credentials from the live cluster
paper-kit-refresh:
    scripts/paper-kit/refresh-embedded.sh

# Browser form on 127.0.0.1 by default; --cli [out.pdf] for terminal prompts.
# Make the paper recovery kit PDF (asks for the cluster's age key)
paper-kit *args:
    scripts/paper-kit/run.sh {{ args }}

# Print ntfy's phone and VPS access tokens (reads the live secret only)
ntfy-tokens:
    @scripts/ntfy-tokens

# Print scrap's MCP token for the claude-canary VPS (reads the live secret only)
scrap-canary-token:
    #!/usr/bin/env bash
    set -euo pipefail
    token=$(kubectl get secret scrap-secrets -n scrap -o jsonpath='{.data.SCRAP_MCP_TOKEN_CANARY}' | base64 -d)
    [ -n "$token" ] || { echo "no canary token: just seal-scrap-secrets --canary new" >&2; exit 1; }
    echo "$token"

# Asks you to type the node name (and `RESET <node>` if the node is in use)
# before changing anything; DRY_RUN=1 previews, FORCE=1 skips the second prompt.
# See docs/how-to/recover-control-plane.md.
# Restore the control plane from a decrypted etcd backup onto a fresh node
restore-control-plane snapshot token_file k3s_version="" node_password="":
    scripts/restore-control-plane "{{ snapshot }}" "{{ token_file }}" "{{ k3s_version }}" "{{ node_password }}"

# Run the encrypted etcd backup on the control plane now and show the result
etcd-backup-now:
    #!/usr/bin/env bash
    set -euo pipefail
    node=$(awk '/^control_plane:/ {print $2}' group_vars/all.yml)
    ssh ansible@"$node" 'sudo systemctl start k3s-etcd-backup.service; \
        sudo journalctl -u k3s-etcd-backup.service -n 20 --no-pager; \
        cat /var/lib/node_exporter/textfile_collector/k3s_etcd_backup.prom | grep -v "^#"'

# Point k3s_api_name at a control-plane IP on the dns_router (OpenWrt, uci)
# and check it resolves here. See docs/how-to/recover-control-plane.md.
k3s-api-dns ip:
    #!/usr/bin/env bash
    set -euo pipefail
    name=$(awk '/^k3s_api_name:/ {print $2}' group_vars/all.yml)
    router=$(awk '/^dns_router:/ {print $2}' group_vars/all.yml)
    [[ -n $name && -n $router ]] || { echo "set k3s_api_name and dns_router in group_vars/all.yml" >&2; exit 1; }
    ip={{ quote(ip) }}
    # Validate here too: the value is spliced into the router's command line.
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "ERROR: '$ip' is not an IPv4 address" >&2; exit 1; }
    [[ $name =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: k3s_api_name '$name' is not a plain DNS name" >&2; exit 1; }
    echo "before: $(getent hosts "$name" || echo "$name does not resolve")"
    ssh "$router" "NAME='$name' IP='$ip' sh -s" < scripts/k3s-api-dns
    after=$(getent hosts "$name" || true)
    echo "after:  ${after:-$name does not resolve}"
    [[ $after == "$ip "* ]] || { echo "ERROR: $name does not resolve to $ip here yet" >&2; exit 1; }

################################################################################
# bootstrap / rebuild — initial install and full teardown/rebuild
################################################################################

# Print vps_relay.forwards as PROTO:PORTS args for scripts/vps-relay-setup on the VPS
vps-relay-forwards:
    @uv run python -c 'import yaml; v = yaml.safe_load(open("kubernetes-services/values.yaml"))["vps_relay"]; print(" ".join(f["protocol"] + ":" + str(f["ports"]) for f in v["forwards"]))'

# Export external credentials (required + optional) to .env at repo root (gitignored)
export-external-creds:
    scripts/export-external-creds

# Generate all secrets fresh and seal in one step (for rebuild)
generate-and-seal-all output_dir="/tmp/cluster-secrets":
    scripts/generate-and-seal-all {{ output_dir }}

# Seal every cluster secret from a generated/extracted JSON file
seal-from-json json_file:
    scripts/seal-from-json {{ json_file }}

# Set the shared admin password (the admin-auth secret Grafana reads).
# Reads ADMIN_PASSWORD env var or prompts interactively.
set-admin-password:
    scripts/set-admin-password

# Reinstall NVIDIA toolkit on GPU nodes and restart device-plugin pods
gpu-setup:
    scripts/gpu-setup

# claude-sandbox recipes. The sandbox is installed by the claude-sandbox
# VS Code extension (not by .devcontainer/postCreate.sh), which puts the
# `claude-sandbox` helper CLI on PATH (`claude-sandbox help` lists it).
#
# Anything that helper covers must NOT be re-wrapped here — the old
# `gh-auth`/`glab-auth`/`promote` recipes were deleted for that reason.
# The two below survive because no subcommand does their job: one applies
# THIS repo's config, the other is a cluster ansible operation.

# Re-apply this repo's sandbox config to /etc/claude-sandbox.conf.
#
# Not redundant with any `claude-sandbox` subcommand: the upstream
# installer (install.sh:install_conf) unconditionally stamps ITS OWN
# .devcontainer/claude-sandbox.conf over /etc/claude-sandbox.conf, so
# an update of the sandbox silently discards our allow-ip entries for the
# cluster nodes and our allow-write binds for /root/{bin,.kube}. Run this
# after every update, or the sandbox loses kubectl and LAN reach.
sandbox-conf:
    install -m 0644 .devcontainer/claude-sandbox.conf /etc/claude-sandbox.conf

# Generate (if absent) and deploy Claude's ansible-account SSH key to all
# cluster nodes. `revoke` removes it. The keypair lives in the iac2-claude-ssh
# podman volume so it persists across container rebuilds. Run this from the
# outer devcontainer — needs the host SSH agent to reach the nodes the first
# time. After deploy, the sandbox can ansible-playbook with this key, which
# is why /root/.config/claude-ssh is an allow-write in claude-sandbox.conf.
# This is a cluster operation, not sandbox tooling — no upstream equivalent.
claude-ssh-bootstrap action="deploy":
    #!/usr/bin/env bash
    set -euo pipefail
    keydir=/root/.config/claude-ssh
    keyfile="$keydir/id_ed25519"
    case "{{ action }}" in
        deploy) state=present ;;
        revoke) state=absent ;;
        *) echo "Usage: just claude-ssh-bootstrap [deploy|revoke]" >&2; exit 1 ;;
    esac
    if [ ! -f "$keyfile" ]; then
        mkdir -p "$keydir"
        chmod 700 "$keydir"
        ssh-keygen -t ed25519 -f "$keyfile" -N "" -C "claude-sandbox@$(hostname)"
    fi
    ansible-playbook pb_all.yml --tags claude_key -e "claude_pubkey_state=$state"
