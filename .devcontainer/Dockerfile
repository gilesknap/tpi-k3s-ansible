# The devcontainer should use the developer target and run as root with podman
# or docker with user namespaces.
FROM ghcr.io/diamondlightsource/ubuntu-devcontainer:noble AS developer

# Add system dependencies for ansible and cluster management
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    apache2-utils \
    dnsutils \
    gh \
    && rm -rf /var/lib/apt/lists/*

# get the claude cli as its slightly more up to date than the vscode extension
curl -fsSL https://claude.ai/install.sh | bash

env PATH=~/.local/bin:$PATH"
