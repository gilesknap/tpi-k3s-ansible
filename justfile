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
    PASSWORD="${ADMIN_PASSWORD:-}"
    if [ -z "$PASSWORD" ]; then printf "Enter admin password: " && read -s PASSWORD < /dev/tty && echo; fi
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

# secret extraction ############################################################

# Export the 8 external credentials (GitHub OAuth, Cloudflare) from the
# running cluster into a .env file at the repo root (gitignored).
# Source this before rebuild so the values survive teardown.
export-external-creds:
    #!/bin/bash
    set -euo pipefail
    get_key() { kubectl get secret "$1" -n "$2" -o jsonpath="{.data.$3}" | base64 -d; }
    cat > .env <<EOF
    GITHUB_CLIENT_ID=$(get_key argocd-dex-secret argo-cd 'dex\.github\.clientID')
    GITHUB_CLIENT_SECRET=$(get_key argocd-dex-secret argo-cd 'dex\.github\.clientSecret')
    CLOUDFLARE_API_TOKEN=$(get_key cloudflare-api-token cert-manager api-token)
    CLOUDFLARE_TUNNEL_TOKEN=$(get_key cloudflared-credentials cloudflared TUNNEL_TOKEN)
    OAUTH2_PROXY_CLIENT_ID=$(get_key oauth2-proxy-credentials oauth2-proxy client-id)
    OAUTH2_PROXY_CLIENT_SECRET=$(get_key oauth2-proxy-credentials oauth2-proxy client-secret)
    OPEN_BRAIN_GITHUB_CLIENT_ID=$(get_key open-brain-mcp-secret open-brain-mcp GITHUB_CLIENT_ID)
    OPEN_BRAIN_GITHUB_CLIENT_SECRET=$(get_key open-brain-mcp-secret open-brain-mcp GITHUB_CLIENT_SECRET)
    EOF
    # Strip leading whitespace from heredoc
    sed -i 's/^[[:space:]]*//' .env
    echo "Wrote .env (8 credentials, gitignored)"
    echo "Source with: set -a && source .env && set +a"

# Extract all plaintext secrets from the running cluster before teardown.
# Writes extracted-secrets.json and sealed-secrets-keys.yaml to OUTPUT_DIR
# (default /tmp/cluster-secrets). Used before rebuild so secrets can be
# re-sealed with the new cluster's sealed-secrets keys.
extract-secrets output_dir="/tmp/cluster-secrets":
    scripts/extract-secrets {{ output_dir }}

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

# Seal all non-Dex secrets from an extracted-secrets JSON file.
# Usage: just seal-from-json /tmp/cluster-secrets/extracted-secrets.json
# Skips secrets handled by seal-argocd-dex. Uses the correct key names
# and output paths for each secret.
seal-from-json json_file:
    #!/bin/bash
    set -euo pipefail
    SEAL="kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml"
    BASE="kubernetes-services/additions"
    JSON="{{ json_file }}"
    if [ ! -f "$JSON" ]; then
        echo "ERROR: JSON file not found: $JSON" >&2
        exit 1
    fi
    # Helper: extract a key value from the JSON for a given secret name and namespace
    get_key() {
        local name="$1" ns="$2" key="$3"
        val=$(jq -r --arg name "$name" --arg ns "$ns" --arg key "$key" \
            '.[] | select(.name == $name and .namespace == $ns) | .data[$key] // empty' "$JSON")
        if [ -z "$val" ]; then
            echo "ERROR: missing key '$key' in secret '$name' (namespace '$ns')" >&2
            exit 1
        fi
        echo "$val"
    }
    # Helper: check a secret exists in the JSON
    has_secret() {
        local name="$1" ns="$2"
        jq -e --arg name "$name" --arg ns "$ns" \
            '.[] | select(.name == $name and .namespace == $ns)' "$JSON" > /dev/null 2>&1
    }
    # 1. cloudflare-api-token (cert-manager)
    echo "Sealing: cloudflare-api-token..."
    kubectl create secret generic cloudflare-api-token --namespace=cert-manager \
        --from-literal=api-token="$(get_key cloudflare-api-token cert-manager api-token)" \
        --dry-run=client -o yaml | $SEAL \
        > "$BASE/cert-manager/templates/cloudflare-api-token-secret.yaml"
    echo "  -> $BASE/cert-manager/templates/cloudflare-api-token-secret.yaml"
    # 2. cloudflared-credentials (cloudflared)
    echo "Sealing: cloudflared-credentials..."
    kubectl create secret generic cloudflared-credentials --namespace=cloudflared \
        --from-literal=TUNNEL_TOKEN="$(get_key cloudflared-credentials cloudflared TUNNEL_TOKEN)" \
        --dry-run=client -o yaml | $SEAL \
        > "$BASE/cloudflared/tunnel-secret.yaml"
    echo "  -> $BASE/cloudflared/tunnel-secret.yaml"
    # 3. oauth2-proxy-credentials (oauth2-proxy)
    echo "Sealing: oauth2-proxy-credentials..."
    kubectl create secret generic oauth2-proxy-credentials --namespace=oauth2-proxy \
        --from-literal=client-secret="$(get_key oauth2-proxy-credentials oauth2-proxy client-secret)" \
        --from-literal=cookie-secret="$(get_key oauth2-proxy-credentials oauth2-proxy cookie-secret)" \
        --from-literal=client-id="$(get_key oauth2-proxy-credentials oauth2-proxy client-id)" \
        --dry-run=client -o yaml | $SEAL \
        > "$BASE/oauth2-proxy/oauth2-proxy-secret.yaml"
    echo "  -> $BASE/oauth2-proxy/oauth2-proxy-secret.yaml"
    # 4. open-brain-mcp-secret (open-brain-mcp)
    echo "Sealing: open-brain-mcp-secret..."
    kubectl create secret generic open-brain-mcp-secret --namespace=open-brain-mcp \
        --from-literal=DATABASE_URL="$(get_key open-brain-mcp-secret open-brain-mcp DATABASE_URL)" \
        --from-literal=MCP_JWT_SECRET="$(get_key open-brain-mcp-secret open-brain-mcp MCP_JWT_SECRET)" \
        --from-literal=GITHUB_CLIENT_ID="$(get_key open-brain-mcp-secret open-brain-mcp GITHUB_CLIENT_ID)" \
        --from-literal=GITHUB_CLIENT_SECRET="$(get_key open-brain-mcp-secret open-brain-mcp GITHUB_CLIENT_SECRET)" \
        --from-literal=SUPABASE_SERVICE_KEY="$(get_key open-brain-mcp-secret open-brain-mcp SUPABASE_SERVICE_KEY)" \
        --dry-run=client -o yaml | $SEAL \
        > "$BASE/open-brain-mcp/templates/open-brain-mcp-secret.yaml"
    echo "  -> $BASE/open-brain-mcp/templates/open-brain-mcp-secret.yaml"
    # 5. supabase-credentials (supabase) — all keys from extracted JSON
    echo "Sealing: supabase-credentials..."
    literals=""
    while IFS= read -r key; do
        val=$(jq -r --arg name "supabase-credentials" --arg ns "supabase" --arg key "$key" \
            '.[] | select(.name == $name and .namespace == $ns) | .data[$key]' "$JSON")
        literals="$literals --from-literal=$key=$val"
    done < <(jq -r '.[] | select(.name == "supabase-credentials" and .namespace == "supabase") | .data | keys[]' "$JSON")
    if [ -z "$literals" ]; then
        echo "ERROR: supabase-credentials not found in JSON" >&2
        exit 1
    fi
    kubectl create secret generic supabase-credentials --namespace=supabase \
        $literals --dry-run=client -o yaml | $SEAL \
        > "$BASE/supabase/templates/supabase-secret.yaml"
    echo "  -> $BASE/supabase/templates/supabase-secret.yaml"
    # 6. supabase-mcp-env (supabase) — MCP_ACCESS_KEY
    # The extracted JSON may have this as mcp-access-key or MCP_ACCESS_KEY;
    # try the extracted secret's key and seal as MCP_ACCESS_KEY.
    echo "Sealing: supabase-mcp-env..."
    if has_secret supabase-mcp-env supabase; then
        # supabase-mcp-env exists as its own secret
        mcp_key=$(jq -r '.[] | select(.name == "supabase-mcp-env" and .namespace == "supabase") | .data | to_entries[0].value' "$JSON")
    else
        echo "ERROR: supabase-mcp-env not found in JSON" >&2
        exit 1
    fi
    kubectl create secret generic supabase-mcp-env --namespace=supabase \
        --from-literal=MCP_ACCESS_KEY="$mcp_key" \
        --dry-run=client -o yaml | $SEAL \
        > "$BASE/supabase/templates/mcp-env-secret.yaml"
    echo "  -> $BASE/supabase/templates/mcp-env-secret.yaml"
    echo ""
    echo "All non-Dex secrets sealed. Run 'just seal-argocd-dex' separately for Dex/OAuth secrets."

# Seal all Dex-related secrets: argocd-dex-secret (all static client
# secrets), argocd-monitor oauth2-proxy, grafana-oauth, open-webui-oauth.
# Prompts for GitHub OAuth credentials. The argo-cd client secret is
# auto-derived from server.secretkey so it matches ArgoCD's internal value.
# All Dex static client secrets (grafana, open-webui, headlamp, argocd-monitor)
# are generated and stored in argocd-dex-secret so $secret:key resolution works.
seal-argocd-dex:
    #!/bin/bash
    set -euo pipefail
    SEAL="kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml"
    client_id="${GITHUB_CLIENT_ID:-}"
    client_secret="${GITHUB_CLIENT_SECRET:-}"
    if [ -z "$client_id" ]; then read -p "GitHub OAuth Client ID: " client_id < /dev/tty; fi
    if [ -z "$client_secret" ]; then read -sp "GitHub OAuth Client Secret: " client_secret < /dev/tty && echo; fi
    # argo-cd client secret: SHA256(server.secretkey as base64 string) → base64url[:40]
    argocd_client_secret=$(kubectl get secret argocd-secret -n argo-cd \
        -o jsonpath='{.data.server\.secretkey}' | base64 -d | \
        python3 -c "import sys,hashlib,base64; print(base64.urlsafe_b64encode(hashlib.sha256(sys.stdin.read().encode()).digest()).decode()[:40])")
    monitor_secret=$(python3 -c "import secrets; print(secrets.token_hex(16))")
    cookie_secret=$(python3 -c "import secrets; print(secrets.token_urlsafe(32)[:32])")
    grafana_secret=$(python3 -c "import secrets; print(secrets.token_hex(16))")
    openwebui_secret=$(python3 -c "import secrets; print(secrets.token_hex(16))")
    headlamp_secret=$(python3 -c "import secrets; print(secrets.token_hex(16))")
    # Dex secret (argo-cd namespace) — GitHub OAuth + ALL static client secrets
    kubectl create secret generic argocd-dex-secret \
      --namespace argo-cd \
      --from-literal=dex.github.clientID="$client_id" \
      --from-literal=dex.github.clientSecret="$client_secret" \
      --from-literal=argo-cd.clientSecret="$argocd_client_secret" \
      --from-literal=argocd.clientSecret="$argocd_client_secret" \
      --from-literal=argocd-monitor.clientSecret="$monitor_secret" \
      --from-literal=grafana.clientSecret="$grafana_secret" \
      --from-literal=open-webui.clientSecret="$openwebui_secret" \
      --from-literal=headlamp.clientSecret="$headlamp_secret" \
      --dry-run=client -o yaml | \
      yq '.metadata.labels["app.kubernetes.io/part-of"] = "argocd"' | \
      $SEAL > kubernetes-services/additions/argocd/argocd-dex-secret.yaml
    echo "Sealed: kubernetes-services/additions/argocd/argocd-dex-secret.yaml"
    # argocd-monitor oauth2-proxy secret
    kubectl create secret generic argocd-monitor-oauth \
      --namespace argocd-monitor \
      --from-literal=client-secret="$monitor_secret" \
      --from-literal=cookie-secret="$cookie_secret" \
      --dry-run=client -o yaml | $SEAL \
      > kubernetes-services/additions/argocd-monitor/argocd-monitor-oauth-secret.yaml
    echo "Sealed: kubernetes-services/additions/argocd-monitor/argocd-monitor-oauth-secret.yaml"
    # Grafana OAuth secret — key must be CLIENT_SECRET (loaded via envFromSecrets)
    kubectl create secret generic grafana-oauth-secret \
      --namespace monitoring \
      --from-literal=CLIENT_SECRET="$grafana_secret" \
      --dry-run=client -o yaml | $SEAL \
      > kubernetes-services/additions/grafana/grafana-oauth-secret.yaml
    echo "Sealed: kubernetes-services/additions/grafana/grafana-oauth-secret.yaml"
    # Open WebUI OAuth secret — key must be client-secret (loaded via secretKeyRef)
    kubectl create secret generic open-webui-oauth-secret \
      --namespace open-webui \
      --from-literal=client-secret="$openwebui_secret" \
      --dry-run=client -o yaml | $SEAL \
      > kubernetes-services/additions/open-webui/open-webui-oauth-secret.yaml
    echo "Sealed: kubernetes-services/additions/open-webui/open-webui-oauth-secret.yaml"

# Generate all secrets fresh and seal them in one step. Used during rebuild
# to eliminate the extract→decommission→seal→second-run cycle. External
# credentials must be set as env vars (see scripts/generate-secrets --help).
# After sealing, also sets the admin password and restarts Dex.
generate-and-seal-all output_dir="/tmp/cluster-secrets":
    #!/bin/bash
    set -euo pipefail
    echo "=== Generating fresh secrets ==="
    scripts/generate-secrets {{ output_dir }}
    JSON="{{ output_dir }}/generated-secrets.json"
    echo ""
    echo "=== Sealing all non-Dex secrets ==="
    just seal-from-json "$JSON"
    echo ""
    echo "=== Sealing Dex/OAuth secrets ==="
    # seal-argocd-dex reads GITHUB_CLIENT_ID/SECRET from env (already set)
    just seal-argocd-dex
    echo ""
    echo "=== Setting admin password ==="
    ADMIN_PASSWORD=$(cat "{{ output_dir }}/admin-password.txt")
    export ADMIN_PASSWORD
    just set-admin-password
    echo ""
    echo "=== All secrets generated, sealed, and admin password set ==="
    echo "Admin password: $ADMIN_PASSWORD"
    echo ""
    echo "Next: commit the sealed secret files and push."

# GPU operations ###############################################################

# Reinstall NVIDIA container toolkit on GPU nodes and restart the
# nvidia-device-plugin pods. Run after k3s reinstall to restore the
# containerd runtime config that GPU pods need.
gpu-setup:
    #!/bin/bash
    set -euo pipefail
    # Find GPU nodes from inventory (nvidia_gpu_node: true)
    gpu_nodes=$(ansible-inventory --list 2>/dev/null | \
        python3 -c "
            import sys, json
            inv = json.load(sys.stdin)
            hosts = inv.get('_meta', {}).get('hostvars', {})
            gpu = [h for h, v in hosts.items() if v.get('nvidia_gpu_node', False)]
            print(','.join(gpu))
        ")
    if [ -z "$gpu_nodes" ]; then
        echo "No GPU nodes found (nvidia_gpu_node: true) in inventory"
        exit 0
    fi
    echo "GPU nodes: $gpu_nodes"
    echo "=== Running --tags servers on GPU nodes ==="
    SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-/tmp/ssh-agent.sock}" \
        ansible-playbook pb_all.yml --tags servers --limit "$gpu_nodes"
    echo ""
    echo "=== Waiting for k3s-agent to restart ==="
    sleep 10
    echo ""
    echo "=== Deleting nvidia-device-plugin pods for fresh rollout ==="
    kubectl delete pod -n nvidia-device-plugin \
        -l app.kubernetes.io/name=nvidia-device-plugin \
        --ignore-not-found
    echo ""
    echo "GPU setup complete. The DaemonSet will create fresh pods with NVIDIA runtime."

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
