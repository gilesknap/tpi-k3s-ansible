# development tasks ############################################################

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

# devcontainer setup ###########################################################

# First-time devcontainer setup: copy SSH keys, authenticate gh, start agent
setup:
    scripts/setup

# Start ssh-agent and add all private keys from ~/.ssh (prompts for passphrases)
ssh-agent:
    scripts/ssh-agent

# Authenticate gh CLI with a GitHub PAT (token not stored in shell history)
gh-auth:
    scripts/gh-auth

# Start Claude Code in sandbox mode (uses container-local SSH agent only)
claude:
    SSH_AUTH_SOCK="/tmp/ssh-agent.sock" IS_SANDBOX=1 claude --dangerously-skip-permissions --chrome

# cluster status & diagnostics #################################################

# Quick cluster health check: nodes, ArgoCD apps, failing pods, certificates
status:
    scripts/status

# Force ArgoCD to re-fetch from git and re-sync all applications
argocd-sync:
    scripts/argocd-sync

# cluster credentials & tokens ################################################

# Set the shared admin password (basic-auth ingresses + ArgoCD admin).
# Reads ADMIN_PASSWORD env var or prompts interactively.
set-admin-password:
    scripts/set-admin-password

# Show Supabase Studio dashboard credentials
supabase-creds:
    @echo "User: $(kubectl get secret supabase-credentials -n supabase -o jsonpath='{.data.username}' | base64 -d)"
    @echo "Pass: $(kubectl get secret supabase-credentials -n supabase -o jsonpath='{.data.dashboard-password}' | base64 -d)"

# Generate a Headlamp login token (valid ~100 days)
headlamp-token:
    @kubectl create token headlamp-admin -n headlamp --duration=2400h

# secret extraction ############################################################

# Export 8 external credentials to .env at repo root (gitignored)
export-external-creds:
    scripts/export-external-creds

# Extract all plaintext secrets from running cluster before teardown
extract-secrets output_dir="/tmp/cluster-secrets":
    scripts/extract-secrets {{ output_dir }}

# sealed secrets ###############################################################

# Seal an arbitrary secret. Usage: just seal <name> <namespace> key1=val1 ...
seal name namespace *args:
    scripts/seal {{ name }} {{ namespace }} {{ args }}

# Seal all non-Dex secrets from an extracted-secrets JSON file
seal-from-json json_file:
    scripts/seal-from-json {{ json_file }}

# Seal all Dex-related secrets (argocd-dex, monitor, grafana, open-webui oauth)
seal-argocd-dex:
    scripts/seal-argocd-dex

# Generate all secrets fresh and seal in one step (for rebuild)
generate-and-seal-all output_dir="/tmp/cluster-secrets":
    scripts/generate-and-seal-all {{ output_dir }}

# GPU operations ###############################################################

# Reinstall NVIDIA toolkit on GPU nodes and restart device-plugin pods
gpu-setup:
    scripts/gpu-setup

# ArgoCD operations ############################################################

# Restart Dex and ArgoCD server (use after changing dex.config or secrets)
restart-dex:
    kubectl rollout restart deployment argocd-dex-server argocd-server argocd-repo-server -n argo-cd
    @echo "Restarted argocd-dex-server, argocd-server, argocd-repo-server"

# Monitoring operations ########################################################

# Create the Prometheus admission webhook TLS secret (required on fresh installs)
create-prometheus-admission-secret:
    scripts/create-prometheus-admission-secret
