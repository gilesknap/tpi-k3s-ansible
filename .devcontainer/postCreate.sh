#!/bin/bash
set -euo pipefail

# Custom initialization goes here if needed.
# Runs inside the dev container after the container is created

uv venv --clear
hash -r
uv sync && pre-commit install --install-hooks

ansible-playbook pb_all.yml --tags tools

# Install claude-sandbox (https://github.com/DiamondLightSource/claude-sandbox)
# — the bwrap jail that `claude` on $PATH resolves to. No sandbox code lives
# in this repo: `uvx` runs the latest published release's installer. It is
# idempotent, so rebuilds re-establish the shadow without re-downloading Claude.
#
# Everything here runs as root at container-create time, OUTSIDE the sandbox
# — review changes to this block as carefully as a Dockerfile change.
uvx claude-sandbox install

# Our config (cluster node allow-ip entries, /workspaces bind, /cache) on top
# of the shipped defaults the installer just stamped into /etc. The shadow
# reads /etc/claude-sandbox.conf at every launch; the workspace copy is never
# read, so a compromised session cannot widen its own binds or network reach.
# Re-apply with `just sandbox-conf` after a `claude-sandbox update`.
install -m 0644 .devcontainer/claude-sandbox.conf /etc/claude-sandbox.conf
