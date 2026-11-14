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

# rclone, for scripts/seal-rclone-drive (the off-site backup's Drive token).
# Pinned and checked against the release's SHA256SUMS.
# Not RCLONE_VERSION: rclone reads RCLONE_<FLAG> env vars, so that would set --version.
ARG RCLONE_RELEASE=1.75.2
ARG RCLONE_SHA256_AMD64=efbfe852181f7191eb3c9043ed1ab49c9b2d0ba045c61c926a5da111c939ec5c
ARG RCLONE_SHA256_ARM64=b8ba161d5c837206fad79ff1aabf0a81aa02a5fb164cdbc0ff5db4160aecd278
RUN set -eu; \
    arch=$(dpkg --print-architecture); \
    case "$arch" in \
        amd64) sha=$RCLONE_SHA256_AMD64 ;; \
        arm64) sha=$RCLONE_SHA256_ARM64 ;; \
        *) echo "no rclone checksum for $arch" >&2; exit 1 ;; \
    esac; \
    deb="rclone-v${RCLONE_RELEASE}-linux-${arch}.deb"; \
    curl -fsSL "https://github.com/rclone/rclone/releases/download/v${RCLONE_RELEASE}/${deb}" -o "/tmp/${deb}"; \
    echo "${sha}  /tmp/${deb}" | sha256sum -c -; \
    dpkg -i "/tmp/${deb}"; \
    rm "/tmp/${deb}"; \
    rclone version
