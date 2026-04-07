# development tasks ############################################################

# Run all checks before committing (lint + docs in parallel)
check:
    #!/bin/bash
    set -euo pipefail
    just lint & pid_lint=$!
    just docs & pid_docs=$!
    fail=0
    wait $pid_lint  || fail=1
    wait $pid_docs  || fail=1
    exit $fail

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
    #!/bin/bash
    set -euo pipefail
    # Check for private keys in ~/.ssh
    keys=$(find ~/.ssh -maxdepth 1 -type f -exec head -1 {} \; 2>/dev/null | grep -c "PRIVATE KEY" || true)
    if [ "$keys" -eq 0 ]; then
        echo "No SSH private keys found in ~/.ssh"
        echo "Copy your ansible keypair into the container, e.g.:"
        echo "  podman cp ~/.ssh/my_ansible_key <container>:/root/.ssh/"
        echo "  podman cp ~/.ssh/my_ansible_key.pub <container>:/root/.ssh/"
        echo ""
        echo "The ~/.ssh volume persists across container rebuilds."
        echo "Re-run 'just setup' after copying keys."
        exit 1
    fi
    echo "=== GitHub CLI authentication ==="
    just gh-auth
    echo ""
    echo "=== SSH agent ==="
    just ssh-agent
    echo ""
    echo "Setup complete. Run 'just claude' to start Claude Code."

# Start ssh-agent and add all private keys from ~/.ssh (prompts for passphrases)
ssh-agent:
    #!/bin/bash
    set -euo pipefail
    sock="/tmp/ssh-agent.sock"
    # Kill any stale agent on this socket
    if [ -S "$sock" ]; then
        SSH_AUTH_SOCK="$sock" ssh-add -l &>/dev/null || rm -f "$sock"
    fi
    # Start agent if not already running
    if [ ! -S "$sock" ]; then
        eval $(command ssh-agent -a "$sock") > /dev/null
        echo "Started ssh-agent (pid $SSH_AGENT_PID)"
    else
        export SSH_AUTH_SOCK="$sock"
        echo "Using existing ssh-agent on $sock"
    fi
    # Add all private keys found in ~/.ssh
    for key in ~/.ssh/*; do
        # Skip non-files, public keys, known_hosts, config, and authorized_keys
        [ -f "$key" ] || continue
        case "$key" in
            *.pub|*known_hosts*|*config*|*authorized_keys*) continue ;;
        esac
        # Check it looks like a private key
        head -1 "$key" 2>/dev/null | grep -q "PRIVATE KEY" || continue
        SSH_AUTH_SOCK="$sock" ssh-add "$key"
    done
    echo ""
    echo "Keys loaded:"
    SSH_AUTH_SOCK="$sock" ssh-add -l
    echo ""
    echo "Run this in your shell to use the agent:"
    echo "  export SSH_AUTH_SOCK=$sock"

# Authenticate gh CLI with a GitHub PAT (token not stored in shell history)
gh-auth:
    #!/bin/bash
    set -euo pipefail
    read -sp "GitHub PAT: " t < /dev/tty && echo
    echo "$t" | gh auth login --with-token
    unset t
    gh auth setup-git
    gh auth status

# Start Claude Code in sandbox mode (uses container-local SSH agent only)
claude:
    SSH_AUTH_SOCK="/tmp/ssh-agent.sock" IS_SANDBOX=1 claude --dangerously-skip-permissions --chrome

# cluster status & diagnostics #################################################

# Quick cluster health check: nodes, ArgoCD apps, failing pods, certificates
status:
    #!/bin/bash
    echo "=== Nodes ==="
    kubectl get nodes 2>&1
    echo ""
    echo "=== ArgoCD Apps ==="
    kubectl get apps -n argo-cd --no-headers 2>&1
    echo ""
    failing=$(kubectl get pods -A --no-headers 2>&1 | grep -v Running | grep -v Completed || true)
    if [ -n "$failing" ]; then
        echo "=== Failing Pods ==="
        echo "$failing"
        echo ""
    fi
    not_ready=$(kubectl get certificates -A --no-headers 2>&1 | grep -v True || true)
    if [ -n "$not_ready" ]; then
        echo "=== Pending Certificates ==="
        echo "$not_ready"
    fi

# Force ArgoCD to re-fetch from git and re-sync all applications
argocd-sync:
    #!/bin/bash
    for app in $(kubectl get apps -n argo-cd -o name); do
        kubectl annotate "$app" -n argo-cd argocd.argoproj.io/refresh=hard --overwrite
    done
    echo "Hard refresh triggered on all ArgoCD apps"

# cluster credentials & tokens ################################################

# Set the shared admin password used by basic-auth ingresses (longhorn,
# grafana, headlamp) and the ArgoCD admin account. Run during initial
# bootstrap or to rotate the password. OAuth handles normal login — this
# is a fallback if oauth2-proxy is down.
set-admin-password:
    #!/bin/bash
    set -euo pipefail
    printf "Enter admin password: " && read -s PASSWORD < /dev/tty && echo
    HTPASSWD=$(htpasswd -nb admin "$PASSWORD")
    for ns in longhorn monitoring headlamp; do
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
        kubectl create secret generic admin-auth -n "$ns" \
            --from-literal=auth="$HTPASSWD" \
            --from-literal=user=admin \
            --from-literal=password="$PASSWORD" \
            --dry-run=client -o yaml | kubectl apply -f -
        echo "Set admin-auth in $ns"
    done
    HASH=$(htpasswd -nbBC 10 "" "$PASSWORD" | tr -d ':\n' | sed 's/$2y/$2a/')
    kubectl -n argo-cd patch secret argocd-secret \
        -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$(date +%FT%T%Z)\"}}"
    kubectl -n argo-cd rollout restart deployment argocd-server
    echo "ArgoCD admin password updated and server restarted"

# Show Supabase Studio dashboard credentials
supabase-creds:
    @echo "User: $(kubectl get secret supabase-credentials -n supabase -o jsonpath='{.data.username}' | base64 -d)"
    @echo "Pass: $(kubectl get secret supabase-credentials -n supabase -o jsonpath='{.data.dashboard-password}' | base64 -d)"

# Generate a Headlamp login token (valid ~100 days). Paste into the
# Headlamp web UI token prompt. Uses the headlamp-admin service account
# which has cluster-admin privileges.
headlamp-token:
    @kubectl create token headlamp-admin -n headlamp --duration=2400h

# sealed secrets ###############################################################

# Seal an arbitrary secret. Usage: just seal <name> <namespace> key1=val1 key2=val2 ...
# Writes the SealedSecret YAML to stdout. Redirect to a file in additions/.
seal name namespace *args:
    #!/bin/bash
    set -euo pipefail
    literals=""
    for kv in {{ args }}; do
        literals="$literals --from-literal=$kv"
    done
    kubectl create secret generic {{ name }} --namespace={{ namespace }} \
        $literals --dry-run=client -o yaml | \
        kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml

# Seal ArgoCD Dex secrets (GitHub OAuth + argocd-monitor oauth2-proxy).
# Prompts for GitHub OAuth credentials. The argo-cd client secret is
# auto-derived from server.secretkey so it matches ArgoCD's internal value.
seal-argocd-dex:
    #!/bin/bash
    set -euo pipefail
    read -p  "GitHub OAuth Client ID: " client_id < /dev/tty
    read -sp "GitHub OAuth Client Secret: " client_secret < /dev/tty && echo
    # argo-cd client secret: SHA256(server.secretkey as base64 string) → base64url[:40]
    argocd_client_secret=$(kubectl get secret argocd-secret -n argo-cd \
        -o jsonpath='{.data.server\.secretkey}' | base64 -d | \
        python3 -c "import sys,hashlib,base64; print(base64.urlsafe_b64encode(hashlib.sha256(sys.stdin.read().encode()).digest()).decode()[:40])")
    monitor_secret=$(python3 -c "import secrets; print(secrets.token_hex(16))")
    cookie_secret=$(python3 -c "import secrets,base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())")
    # Dex secret (argo-cd namespace) — GitHub OAuth + static client secrets
    kubectl create secret generic argocd-dex-secret \
      --namespace argo-cd \
      --from-literal=dex.github.clientID="$client_id" \
      --from-literal=dex.github.clientSecret="$client_secret" \
      --from-literal=argo-cd.clientSecret="$argocd_client_secret" \
      --from-literal=argocd.clientSecret="$argocd_client_secret" \
      --from-literal=argocd-monitor.clientSecret="$monitor_secret" \
      --dry-run=client -o yaml | \
      yq '.metadata.labels["app.kubernetes.io/part-of"] = "argocd"' | \
      kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml \
      > kubernetes-services/additions/argocd/argocd-dex-secret.yaml
    echo "Sealed: kubernetes-services/additions/argocd/argocd-dex-secret.yaml"
    # argocd-monitor oauth2-proxy secret (argocd-monitor namespace)
    kubectl create secret generic argocd-monitor-oauth \
      --namespace argocd-monitor \
      --from-literal=client-secret="$monitor_secret" \
      --from-literal=cookie-secret="$cookie_secret" \
      --dry-run=client -o yaml | \
      kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml \
      > kubernetes-services/additions/argocd-monitor/argocd-monitor-oauth-secret.yaml
    echo "Sealed: kubernetes-services/additions/argocd-monitor/argocd-monitor-oauth-secret.yaml"

# ArgoCD operations ############################################################

# Restart Dex and ArgoCD server. Use after changing dex.config, re-sealing
# the dex secret, or if OAuth login is broken.
restart-dex:
    kubectl rollout restart deployment argocd-dex-server argocd-server argocd-repo-server -n argo-cd
    @echo "Restarted argocd-dex-server, argocd-server, argocd-repo-server"

# Monitoring operations ########################################################

# Create the Prometheus admission webhook TLS secret. Required on fresh
# installs because ArgoCD prunes the Helm hook job that normally creates it.
create-prometheus-admission-secret:
    #!/bin/bash
    set -euo pipefail
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" \
        -days 365 -nodes \
        -subj '/CN=grafana-prometheus-kube-pr-admission.monitoring.svc' 2>/dev/null
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic grafana-prometheus-kube-pr-admission \
        -n monitoring \
        --from-file=cert="$TMPDIR/cert.pem" \
        --from-file=key="$TMPDIR/key.pem" \
        --from-file=ca="$TMPDIR/cert.pem" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "Created grafana-prometheus-kube-pr-admission secret in monitoring namespace"
