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

# After scrap's move to NFS: list writes in the frozen old database
# that the live one lacks (read-only on both sides)
scrap-cutover-check node="nuc2":
    scripts/scrap-cutover-check {{ node }}

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

# Print ntfy's phone and VPS access tokens (reads the live secret only)
ntfy-tokens:
    @scripts/ntfy-tokens

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

# Set the shared admin password (basic-auth ingresses + ArgoCD admin).
# Reads ADMIN_PASSWORD env var or prompts interactively.
set-admin-password:
    scripts/set-admin-password

# Reinstall NVIDIA toolkit on GPU nodes and restart device-plugin pods
gpu-setup:
    scripts/gpu-setup

# Create the Prometheus admission webhook TLS secret (required on fresh installs)
create-prometheus-admission-secret:
    scripts/create-prometheus-admission-secret

# claude-sandbox recipes. The sandbox is installed from its upstream
# release by .devcontainer/postCreate.sh, which puts the `claude-sandbox`
# helper CLI on PATH: gh-auth, glab-auth, update, verify, version.
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
# `claude-sandbox update` silently discards our allow-ip entries for the
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
