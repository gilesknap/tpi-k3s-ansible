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

# language specific features ###################################################

# Run ansible-lint
lint:
    uv run ansible-lint

# generic development tasks ####################################################

# Build Sphinx documentation
docs:
    uv run sphinx-build --fresh-env --show-traceback --fail-on-warning --keep-going docs build/html

# Auto-rebuild docs on change
docs-watch:
    uv run sphinx-autobuild --show-traceback --watch README.md docs build/html

# Run pre-commit hooks on all files
pre-commit:
    uv run pre-commit run --all-files --show-diff-on-failure

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

# Start Claude Code in sandbox mode (uses container-local SSH agent only)
claude:
    SSH_AUTH_SOCK="/tmp/ssh-agent.sock" IS_SANDBOX=1 claude --dangerously-skip-permissions
