#!/usr/bin/env bash
# claude-sandbox promote: make a target host workspace a self-sufficient
# claude-sandbox host. After a successful promote, a teammate who
# clones the target only needs the devcontainer to come up — the
# installer runs from postCreate and the curated `.claude/` is in tree.
#
# Three layers of effect, in order:
#
# 1. Curated `.claude/` content (commands, skills, hooks, statusline,
#    sandbox-check hook + statusLine wiring into settings.json).
# 2. Install machinery (`.devcontainer/claude-sandbox/{install.sh,
#    claude-shadow, promote.sh}` + root `justfile`) so postCreate can
#    run install.sh directly and `just promote`/`just gh-auth` work in
#    the target the same way they do in the source clone. The source
#    repo's root `install` shim is NOT copied — it's the source-repo
#    UX entry, not a promoted-target workflow.
# 3. `.devcontainer/postCreate.sh` runs
#    `bash .devcontainer/claude-sandbox/install.sh`; we then print the
#    one-line JSON snippet the user pastes into devcontainer.json so
#    install runs automatically on devcontainer create. We do NOT edit
#    devcontainer.json — it's JSONC in the wild and the user knows
#    whether they've already wired it or need to combine with their own.
#
# Idempotent: re-runs are byte-stable via install_file's `cmp -s`
# short-circuit and the dedup/refuse logic in each wire_* step.
#
# Does NOT touch `~/.claude` — that channel is reserved for
# cross-container shared state (OAuth, memories). Issue #18 spells out
# the rationale.
#
# Usage:
#   bash .devcontainer/claude-sandbox/promote.sh [TARGET]
#   just promote [TARGET]                              # preferred
#
# TARGET defaults to $PWD. The script refuses when TARGET resolves to
# the sandbox clone itself — promoting onto yourself is a no-op the
# user almost certainly didn't mean.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT is the clone — two levels above .devcontainer/claude-sandbox.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TARGET_INPUT="${1:-$PWD}"
if [ ! -d "$TARGET_INPUT" ]; then
    echo "claude-sandbox: refusing — target '$TARGET_INPUT' is not a directory." >&2
    exit 1
fi
TARGET="$(cd "$TARGET_INPUT" && pwd)"

if [ "$TARGET" = "$REPO_ROOT" ]; then
    echo "claude-sandbox: refusing — target is the sandbox repo itself; nothing to promote." >&2
    exit 1
fi

# Hand WORKSPACE off to install.sh's wire_settings_{hook,statusline} —
# they operate on "$WORKSPACE/.claude/settings.json".
INSTALL_WORKSPACE="$TARGET"
export INSTALL_WORKSPACE
# shellcheck source=./install.sh
. "$SCRIPT_DIR/install.sh"

# copy_tree: install_file every regular file under $1 to the same
# relative path under $2. install_file's `cmp -s` short-circuit makes
# re-runs no-ops; mode 0755 matches what install.sh already uses for
# the hook and statusline (skill .md files end up 0755 too — harmless,
# users can `chmod 0644` if they care).
copy_tree() {
    local src_dir="$1" dst_dir="$2"
    [ -d "$src_dir" ] || return 0
    local src rel
    while IFS= read -r -d '' src; do
        rel="${src#"$src_dir/"}"
        install_file "$src" "$dst_dir/$rel"
    done < <(find "$src_dir" -type f -print0)
}

# wire_postcreate_script: ensure <target>/.devcontainer/postCreate.sh
# exists and runs `.devcontainer/claude-sandbox/install.sh`. If a
# postCreate.sh is already there, append our line unless an installer
# invocation is already present. Final mode is 0755 so
# devcontainer.json's `"postCreateCommand": ".devcontainer/postCreate.sh"`
# form works without an explicit `bash` prefix.
wire_postcreate_script() {
    local pc="$TARGET/.devcontainer/postCreate.sh"
    local install_cmd="bash .devcontainer/claude-sandbox/install.sh"
    mkdir -p "$(dirname "$pc")"

    if [ ! -f "$pc" ]; then
        cat > "$pc" <<EOF
#!/usr/bin/env bash
# postCreate: run the claude-sandbox installer baked in by
# 'just promote'. Idempotent so devcontainer rebuilds re-establish
# the shadow without re-downloading Claude.
set -euo pipefail

$install_cmd
EOF
        chmod 0755 "$pc"
        return 0
    fi

    if grep -Eq '^[[:space:]]*bash[[:space:]]+\.devcontainer/claude-sandbox/install\.sh' "$pc"; then
        chmod 0755 "$pc"
        return 0
    fi

    {
        printf '\n# claude-sandbox: bring up the sandbox (added by just promote).\n'
        printf '%s\n' "$install_cmd"
    } >> "$pc"
    chmod 0755 "$pc"
}

# print_devcontainer_snippet: print the JSON the user should paste into
# their devcontainer.json. We deliberately do NOT inspect or edit
# devcontainer.json — it is almost always JSONC, structured editing
# while preserving comments is non-trivial, and the user is the one
# who knows whether they already wired this in (or whether their
# existing postCreateCommand needs combining with ours). Trust them.
print_devcontainer_snippet() {
    local pc_cmd=".devcontainer/postCreate.sh"
    cat >&2 <<EOF

claude-sandbox: to auto-install the sandbox on devcontainer create,
ensure $TARGET/.devcontainer/devcontainer.json runs postCreate.sh.
Paste (or chain into your existing postCreateCommand):

    "postCreateCommand": "$pc_cmd"

(One-time edit. If you've already wired it, ignore this.)
EOF
}

# Layer 1: curated .claude/ content + settings merge.
copy_tree "$REPO_ROOT/.claude/commands" "$TARGET/.claude/commands"
copy_tree "$REPO_ROOT/.claude/skills"   "$TARGET/.claude/skills"
copy_tree "$REPO_ROOT/.claude/hooks"    "$TARGET/.claude/hooks"
install_file "$REPO_ROOT/.claude/statusline-command.sh" \
             "$TARGET/.claude/statusline-command.sh"
wire_settings_hook
wire_settings_statusline

# Layer 2: install machinery — the target becomes self-installing so a
# teammate doesn't need a second clone of claude-sandbox. The root
# `install` shim is NOT copied; promoted repos invoke install.sh
# directly from postCreate.sh. The shim is the source repo's manual-UX
# entry (`./install`) and isn't a primary workflow for targets.
install_file "$SCRIPT_DIR/install.sh"    "$TARGET/.devcontainer/claude-sandbox/install.sh"
install_file "$SCRIPT_DIR/claude-shadow" "$TARGET/.devcontainer/claude-sandbox/claude-shadow"
install_file "$SCRIPT_DIR/promote.sh"    "$TARGET/.devcontainer/claude-sandbox/promote.sh"

# Root justfile — the recipes shipped here (promote, gh-auth,
# glab-auth) are workflow tools a promoted host needs too. Recipes
# specific to the source repo (test/upgrade/verify) were dropped so
# this file is a verbatim copy. install_file overwrites on diff —
# if the target already has a justfile, promote will replace it.
install_file "$REPO_ROOT/justfile" "$TARGET/justfile"

# Layer 3: devcontainer wiring — write/append postCreate.sh (a shell
# script we own; trivial to edit), then print the JSON snippet for the
# user to paste into devcontainer.json. devcontainer.json is JSONC in
# the wild and structured editing is more code than this repo wants —
# the user pastes once, after which the file is byte-stable.
wire_postcreate_script
print_devcontainer_snippet

echo "claude-sandbox: promote complete."
echo "  source:   $REPO_ROOT"
echo "  target:   $TARGET"
echo "  next:     open $TARGET in a devcontainer (postCreate will install),"
echo "            or 'bash .devcontainer/claude-sandbox/install.sh' inside it."
