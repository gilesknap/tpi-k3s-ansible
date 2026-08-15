# Thin overlay over upstream rkllama: applies in-tree patches at build
# time. Keeps us off a hard fork while we wait for upstream merges.
#
# Pin the base to a content digest so rebuilds are reproducible. To bump:
#   curl -s "https://ghcr.io/token?scope=repository:notpunchnox/rkllama:pull" \
#     | python -c 'import sys,json; print(json.load(sys.stdin)["token"])' \
#     | xargs -I{} curl -sI -H 'Authorization: Bearer {}' \
#       -H 'Accept: application/vnd.oci.image.index.v1+json' \
#       https://ghcr.io/v2/notpunchnox/rkllama/manifests/main \
#     | grep -i docker-content-digest
FROM ghcr.io/notpunchnox/rkllama@sha256:3ab91181b5caf1f4f3e4e55f5c0d7e9ef7f261a13c81752fc85d728fad92effe

COPY patches/ /tmp/patches/
RUN set -e; \
    cd /opt/rkllama; \
    for p in /tmp/patches/*.patch; do \
      echo "Applying $p"; \
      patch -p1 --no-backup-if-mismatch < "$p"; \
    done; \
    rm -rf /tmp/patches
