#!/bin/bash
set -euo pipefail

# Custom initialization goes here if needed.
# Runs inside the dev container after the container is created

uv venv --clear
hash -r
uv sync && pre-commit install --install-hooks

ansible-playbook pb_all.yml --tags tools

# Node host keys into /etc/ssh/ssh_known_hosts (and ~/.ssh/known_hosts).
# The Claude sandbox has no ~/.ssh, so the system-wide file — which it sees
# read-only — is the only way its ssh/ansible can verify the nodes. /etc is
# rebuilt with the container, so repopulate it here. Unreachable nodes must
# not abort container creation.
ansible-playbook pb_all.yml --tags known_hosts ||
    echo "WARNING: known_hosts update failed; re-run: ansible-playbook pb_all.yml --tags known_hosts"

# claude-sandbox (https://github.com/DiamondLightSource/claude-sandbox), the
# bwrap jail that `claude` on $PATH resolves to, is installed by the
# claude-sandbox VS Code extension, not here: installing it in this script
# too ran the installer twice.

# Our config (cluster node allow-ip entries, /workspaces bind, /cache) on top
# of the shipped defaults the claude-sandbox installer stamps into /etc. The shadow
# reads /etc/claude-sandbox.conf at every launch; the workspace copy is never
# read, so a compromised session cannot widen its own binds or network reach.
# Re-apply with `just sandbox-conf` after the sandbox is updated.
install -m 0644 .devcontainer/claude-sandbox.conf /etc/claude-sandbox.conf
