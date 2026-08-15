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

# Restart Dex and ArgoCD server (use after changing dex.config or secrets)
restart-dex:
    kubectl rollout restart deployment argocd-dex-server argocd-server argocd-repo-server -n argo-cd
    @echo "Restarted argocd-dex-server, argocd-server, argocd-repo-server"

# Show Supabase Studio dashboard credentials
supabase-creds:
    @echo "User: $(kubectl get secret supabase-credentials -n supabase -o jsonpath='{.data.username}' | base64 -d)"
    @echo "Pass: $(kubectl get secret supabase-credentials -n supabase -o jsonpath='{.data.dashboard-password}' | base64 -d)"

# Generate a 100 day Headlamp ServiceAccount token (paste into the login page after OAuth)
headlamp-token:
    @kubectl create token headlamp -n headlamp --duration=2400h

# Rotate a single Dex-related secret in the live cluster. Subcommand required:
# github, argocd, monitor, grafana, open-webui, slack (see scripts/seal-argocd-dex help)
seal-argocd-dex target:
    scripts/seal-argocd-dex {{ target }}

################################################################################
# bootstrap / rebuild — initial install and full teardown/rebuild
################################################################################

# Export 8 external credentials to .env at repo root (gitignored)
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
