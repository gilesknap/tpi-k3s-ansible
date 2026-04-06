#!/bin/bash
set -euo pipefail

# Custom initialization goes here if needed.
# Runs inside the dev container after the container is created

################################################################################
# Claude Code CLI
################################################################################

# Install at container-create time so the image layer stays small and the CLI
# is always the latest version.
curl -fsSL https://claude.ai/install.sh | bash
export PATH="/root/.local/bin:$PATH"


################################################################################
# Container-local SSH agent
################################################################################

# Start a local ssh-agent (host agent is blocked via SSH_AUTH_SOCK="").
# The socket path is written to /etc/profile.d so all shells pick it up.
# After container start, run: ssh-add /root/.ssh/giles_ansible
AGENT_SOCK="/tmp/ssh-agent.sock"
cat > /etc/profile.d/ssh-agent.sh << 'AGENT_EOF'
AGENT_SOCK="/tmp/ssh-agent.sock"
if [ ! -S "$AGENT_SOCK" ]; then
    eval $(ssh-agent -a "$AGENT_SOCK") > /dev/null
fi
export SSH_AUTH_SOCK="$AGENT_SOCK"
AGENT_EOF
chmod +x /etc/profile.d/ssh-agent.sh
