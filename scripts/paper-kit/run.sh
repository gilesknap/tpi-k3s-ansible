#!/usr/bin/env bash
# Make the paper kit PDF. Puts ~/bin first on PATH so age/age-keygen are found
# (the devcontainer image doesn't ship age yet).
#
# Usage: scripts/paper-kit/run.sh              browser form on 127.0.0.1 (default)
#        scripts/paper-kit/run.sh --cli [out.pdf]   terminal prompts instead
# See docs/how-to/paper-kit.md.
set -euo pipefail
export PATH="$HOME/bin:$PATH"
command -v age-keygen >/dev/null || { echo "age-keygen not found (on PATH or in ~/bin)" >&2; exit 1; }
cd "$(dirname "$0")/../.."
kit=scripts/paper-kit/make-paper-kit.py

case "${1:-}" in
    --cli | --splice-creds | -h | --help) exec uv run "$kit" "$@" ;;
esac

# Browser mode. The kit prints exactly one line on stdout, the URL (with its
# one-time token); show it and try to open it in a browser. Failing to open
# one is harmless: open the printed URL by hand.
open_url() {
    if [ -n "${BROWSER:-}" ]; then
        "$BROWSER" "$1" >/dev/null 2>&1 &
    elif command -v xdg-open >/dev/null; then
        xdg-open "$1" >/dev/null 2>&1 &
    fi
}
uv run "$kit" --gui | while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
        http://127.0.0.1:*) open_url "$line" || true ;;
    esac
done
