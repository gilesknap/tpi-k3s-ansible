# The devcontainer should use the developer target and run as root with podman
# or docker with user namespaces.
FROM ghcr.io/diamondlightsource/ubuntu-devcontainer:noble AS developer

# Add system dependencies for ansible and cluster management
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    apache2-utils \
    dnsutils \
    gh \
    jq \
    just \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture) \
       -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# OpenTofu, for the Cloudflare config in cloudflare/ (just cf-plan).
# Pinned and checked against the release's tofu_<version>_SHA256SUMS.
ARG TOFU_VERSION=1.13.2
ARG TOFU_SHA256_AMD64=ac05d9952662c7db28dd57e93f0a68018837bfdf9342384ec0987977c16a9645
ARG TOFU_SHA256_ARM64=88e2d9e3f94f97b76ab2faf55ade87578f56aed19c5e45fa139d70e994366d1f
RUN set -eu; \
    arch=$(dpkg --print-architecture); \
    case "$arch" in \
        amd64) sha=$TOFU_SHA256_AMD64 ;; \
        arm64) sha=$TOFU_SHA256_ARM64 ;; \
        *) echo "no OpenTofu checksum for $arch" >&2; exit 1 ;; \
    esac; \
    tarball="tofu_${TOFU_VERSION}_linux_${arch}.tar.gz"; \
    curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/${tarball}" -o "/tmp/${tarball}"; \
    echo "${sha}  /tmp/${tarball}" | sha256sum -c -; \
    tar -xzf "/tmp/${tarball}" -C /usr/local/bin tofu; \
    rm "/tmp/${tarball}"; \
    tofu version
