#!/usr/bin/env bash
# claude-sandbox installer (bash-only). Idempotent: re-runs after a
# devcontainer rebuild re-establish container state without disturbing
# workspace edits.
#
# Two configurable seams for tests:
#   INSTALL_PREFIX   (default /)   — root of file placement, so
#                                    tests/smoke.sh can drop everything
#                                    into a tmpdir.
#   INSTALL_WORKSPACE (default $PWD) — workspace whose `.claude/` gets
#                                    the settings+hook wired in.
#   CLAUDE_SANDBOX_SMOKE=1            skip apt + curl-install-claude.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT is the clone — two levels above .devcontainer/claude-sandbox.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFIX="${INSTALL_PREFIX:-/}"
WORKSPACE="${INSTALL_WORKSPACE:-$PWD}"
SMOKE="${CLAUDE_SANDBOX_SMOKE:-0}"

# Resolve a target under $PREFIX. Stripping the leading slash lets us
# compose relative-to-prefix paths cleanly without a `//` between root
# and the absolute path.
prefixed() {
    local abs="$1"
    if [ "$PREFIX" = "/" ]; then
        printf '%s\n' "$abs"
    else
        printf '%s\n' "${PREFIX%/}${abs}"
    fi
}

probe_or_refuse() {
    if [ "$SMOKE" = "1" ]; then
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "claude-sandbox: refusing — Debian/Ubuntu only (no apt-get on PATH)." >&2
        exit 1
    fi
}

apt_install() {
    if [ "$SMOKE" = "1" ]; then
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        bubblewrap just jq curl ca-certificates git nodejs gh
    # glab isn't in every Ubuntu repo; install-try.
    apt-get install -y -qq --no-install-recommends glab 2>/dev/null || true
}

probe_userns_or_refuse() {
    if [ "$SMOKE" = "1" ]; then
        return 0
    fi
    if ! bwrap --ro-bind / / --unshare-user-try --unshare-pid -- /bin/true \
            >/dev/null 2>&1; then
        cat >&2 <<'EOF'
claude-sandbox: refusing — kernel unprivileged user namespaces are
forbidden. The bwrap sandbox cannot start without them.

On Ubuntu 24.04:
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
On rootful Docker with default AppArmor: rebuild the devcontainer
under rootless podman, or relax AppArmor for bwrap.
EOF
        exit 1
    fi
}

# install_claude_binary: fetch the real Claude via the official
# installer, then relocate it to a path that is NOT on the user's
# PATH. The official installer drops the binary at ~/.local/bin/claude
# AND prepends ~/.local/bin to the user's shell rc — meaning plain
# `claude` would resolve past our shadow once a new shell starts. By
# moving the binary to /usr/libexec/claude-sandbox/, ~/.local/bin/
# stays empty and the rc-mutation becomes harmless.
install_claude_binary() {
    if [ "$SMOKE" = "1" ]; then
        return 0
    fi
    local real_dest
    real_dest="$(prefixed /usr/libexec/claude-sandbox/claude)"
    if [ -x "$real_dest" ]; then
        # Idempotent: purge any stale copy a prior curl-install may have
        # left at ~/.local/bin/claude so the shadow remains the only
        # `claude` on the user's PATH.
        rm -f "$HOME/.local/bin/claude"
        return 0
    fi
    curl -fsSL https://claude.ai/install.sh | bash
    if [ ! -x "$HOME/.local/bin/claude" ]; then
        echo "claude-sandbox: official installer did not produce \$HOME/.local/bin/claude" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$real_dest")"
    mv "$HOME/.local/bin/claude" "$real_dest"
}

# install_file: byte-stable copy of src → dst at mode 0755. Refuses
# if src is missing (loud-fail beats a downstream errno). cmp -s
# short-circuits so a re-run is a true no-op when content matches.
install_file() {
    local src="$1" dst="$2"
    if [ ! -f "$src" ]; then
        echo "claude-sandbox: cannot find $src" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    install -m 0755 "$src" "$dst"
}

ensure_cred_dirs() {
    mkdir -p "$HOME/.config/gh" "$HOME/.config/glab-cli"
    touch "$HOME/.claude.json"
}

# link_terminal_config: when /user-terminal-config is mounted (the
# convention used by terminal-config-style devcontainers), symlink
# ~/.claude and ~/.claude.json into it so Claude's settings and OAuth
# state are shared across every devcontainer on the host. Runs before
# install_claude_binary so the destinations are guaranteed-clean; a
# pre-existing destination (this repo's bind mount, or a previous
# install) makes ln a no-op via the -e/-L guards.
link_terminal_config() {
    local shared="${CLAUDE_SHARED_CONFIG:-/user-terminal-config}"
    [ -d "$shared" ] || return 0
    mkdir -p "$shared/.claude"
    [ -e "$shared/.claude.json" ] || : > "$shared/.claude.json"
    [ -e "$HOME/.claude" ]      || [ -L "$HOME/.claude" ]      || ln -s "$shared/.claude"      "$HOME/.claude"
    [ -e "$HOME/.claude.json" ] || [ -L "$HOME/.claude.json" ] || ln -s "$shared/.claude.json" "$HOME/.claude.json"
}

# wire_settings_hook: surgical UserPromptSubmit-hook merge into
# <workspace>/.claude/settings.json.
#   - file absent → write minimal {"hooks":{"UserPromptSubmit":[...]}}.
#   - file parses as JSON via jq → merge, dedup by command basename.
#   - file is JSONC (jq parse fails) → refuse with paste-this snippet.
#   - existing entry with same basename but different command → refuse.
wire_settings_hook() {
    local settings="$WORKSPACE/.claude/settings.json"
    local hook_cmd=".claude/hooks/sandbox-check.sh"
    mkdir -p "$(dirname "$settings")"

    local minimal
    minimal="$(jq -n --arg cmd "$hook_cmd" '{
        hooks: {
            UserPromptSubmit: [
                {hooks: [{type: "command", command: $cmd}]}
            ]
        }
    }')"

    if [ ! -f "$settings" ]; then
        printf '%s\n' "$minimal" > "$settings"
        chmod 0644 "$settings"
        return 0
    fi

    if ! jq -e . "$settings" >/dev/null 2>&1; then
        cat >&2 <<EOF
claude-sandbox: refusing — $settings is JSONC (jq parse failed).
Please paste the following snippet by hand into the file:

$minimal

EOF
        exit 1
    fi

    # Dedup by command basename. If an entry with basename
    # sandbox-check.sh exists with a *different* command, refuse.
    local existing_conflict
    existing_conflict="$(jq -r --arg base "sandbox-check.sh" --arg cmd "$hook_cmd" '
        (.hooks.UserPromptSubmit // [])
        | map(.hooks // [])
        | flatten
        | map(select(.command != null and (.command | split("/") | last) == $base and .command != $cmd))
        | .[0].command // empty
    ' "$settings")"
    if [ -n "$existing_conflict" ]; then
        echo "claude-sandbox: refusing — $settings already has a sandbox-check.sh hook at '$existing_conflict' that differs from our '$hook_cmd'. Reconcile manually." >&2
        exit 1
    fi

    local merged tmp
    merged="$(jq --arg cmd "$hook_cmd" '
        .hooks //= {}
        | .hooks.UserPromptSubmit //= []
        | if any(.hooks.UserPromptSubmit[].hooks[]?; .command == $cmd) then .
          else .hooks.UserPromptSubmit += [
              {hooks: [{type: "command", command: $cmd}]}
            ]
          end
    ' "$settings")"
    tmp="$(mktemp "$settings.XXXXXX")"
    printf '%s\n' "$merged" > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$settings"
}

# wire_settings_statusline: stamp our .statusLine into settings.json
# iff the field is absent. Any pre-existing .statusLine — ours or the
# user's — is left alone, so a user who customised theirs keeps it
# across rebuilds. wire_settings_hook runs first and guarantees the
# file exists and parses as JSON, so no JSONC branch is needed here.
wire_settings_statusline() {
    local settings="$WORKSPACE/.claude/settings.json"
    local sl_cmd=".claude/statusline-command.sh"

    if jq -e '.statusLine' "$settings" >/dev/null 2>&1; then
        return 0
    fi

    local merged tmp
    merged="$(jq --arg cmd "$sl_cmd" '
        .statusLine = {type: "command", command: $cmd}
    ' "$settings")"
    tmp="$(mktemp "$settings.XXXXXX")"
    printf '%s\n' "$merged" > "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$settings"
}

main() {
    probe_or_refuse
    # Shadow first: with /usr/local/bin/claude in place before the
    # official installer runs, any `claude` lookup during the rest of
    # install resolves (and bash-hashes) to the shadow path, even if
    # the shadow itself transiently fails because bwrap or the real
    # binary haven't landed yet.
    install_file "$SCRIPT_DIR/claude-shadow" "$(prefixed /usr/local/bin/claude)"
    apt_install
    probe_userns_or_refuse
    link_terminal_config
    install_claude_binary
    ensure_cred_dirs
    install_file "$REPO_ROOT/.claude/hooks/sandbox-check.sh" \
                 "$WORKSPACE/.claude/hooks/sandbox-check.sh"
    install_file "$REPO_ROOT/.claude/statusline-command.sh" \
                 "$WORKSPACE/.claude/statusline-command.sh"
    wire_settings_hook
    wire_settings_statusline

    echo "claude-sandbox: install complete."
    echo "  shadow:      $(prefixed /usr/local/bin/claude)"
    echo "  real claude: $(prefixed /usr/libexec/claude-sandbox/claude)"
    echo "  workspace:   $WORKSPACE"
    echo "  run \`/verify-sandbox\` inside Claude for the live battery."
}

# Source guard: `promote.sh` re-uses `install_file`,
# `wire_settings_hook`, and `wire_settings_statusline` by sourcing this
# file. The guard keeps main() from auto-running in that case.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
