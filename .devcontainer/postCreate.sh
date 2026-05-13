#!/bin/bash
set -euo pipefail

# Custom initialization goes here if needed.
# Runs inside the dev container after the container is created

uv venv --clear
hash -r
uv sync && pre-commit install --install-hooks

# claude-sandbox: bring up the sandbox (added by just promote).
bash .devcontainer/claude-sandbox/install.sh

ansible-playbook pb_all.yml --tags tools
