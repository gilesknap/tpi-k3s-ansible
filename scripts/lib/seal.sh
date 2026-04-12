#!/usr/bin/env bash
# Shared helpers for kubeseal-based scripts. Source from a bash script:
#   . "$(dirname "$0")/lib/seal.sh"

SEAL="kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml"

# Atomic seal: write to temp file, move on success. Prevents truncating
# existing sealed secrets when kubeseal fails (e.g. controller not ready).
seal_to() {
    local dest="$1"
    local tmp="${dest}.tmp"
    if $SEAL > "$tmp"; then
        mv "$tmp" "$dest"
    else
        rm -f "$tmp"
        echo "ERROR: kubeseal failed for $dest" >&2
        exit 1
    fi
}
