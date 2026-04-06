# The devcontainer should use the developer target and run as root with podman
# or docker with user namespaces.
FROM ghcr.io/diamondlightsource/ubuntu-devcontainer:noble AS developer

# Add system dependencies for ansible and cluster management
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    apache2-utils \
    dnsutils \
    gh \
    just \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture) \
       -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
