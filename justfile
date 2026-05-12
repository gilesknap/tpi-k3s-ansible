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

# claude-sandbox recipes. Shipped verbatim into promoted targets via
# `just promote`, so every recipe here must be useful in both the
# source clone and a promoted host workspace.

# Seed the sandbox's curated `.claude/` (commands, skills, hooks,
# statusline, sandbox-check hook) into a target host workspace. See
# .devcontainer/claude-sandbox/promote.sh for the rationale.
promote target=invocation_directory():
    bash .devcontainer/claude-sandbox/promote.sh {{ target }}

# Authenticate gh CLI with a GitHub PAT (token not stored in shell history).
gh-auth:
    #!/usr/bin/env bash
    cat <<'EOF'
    Create or renew a fine-grained PAT at:
      https://github.com/settings/personal-access-tokens

    Recommended settings for a sandboxed Claude Code:
      - Resource owner: your user (or org that owns this repo)
      - Repository access: Only select repositories -> just this repo
      - Expiration: short (e.g. 30 days) so a leaked token expires quickly
      - Repository permissions (Read and Write):
          Contents, Issues, Pull requests
        (Metadata: Read-only is added automatically)
      - Leave everything else unset / no access

    EOF
    read -sp "GitHub PAT: " t && echo
    echo "$t" | gh auth login --with-token
    unset t
    gh auth setup-git
    gh auth status

# Authenticate glab CLI with a GitLab PAT (token not stored in shell history).
# --git-protocol https prevents glab's SSH insteadOf rewrite.
glab-auth hostname="gitlab.com":
    #!/usr/bin/env bash
    cat <<'EOF'
    Create or renew a fine-grained PAT at:
      https://gitlab.com/-/user_settings/personal_access_tokens
      (or your organisation's GitLab instance equivalent)

    Recommended scopes for a sandboxed Claude Code:
      - api, read_repository, write_repository
      - Short expiration so a leaked token expires quickly

    EOF
    read -sp "GitLab PAT for {{ hostname }}: " t && echo
    echo "$t" | glab auth login --stdin --hostname {{ hostname }} --git-protocol https
    unset t
    glab auth status
