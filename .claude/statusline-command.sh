#!/usr/bin/env bash
# Claude Code status line: model + context usage.
#
# Reads Claude's JSON status payload from stdin and prints a colored
# one-liner: username · model · cwd · ctx · cost. Uses jq for JSON
# parsing so no python is needed — works fine inside the bwrap sandbox
# where the host's python is masked off. If jq is missing, falls
# through to a bash-only degraded line.

input=$(cat)

degraded_line() {
    local username cwd short_cwd
    username=$(whoami 2>/dev/null || echo "?")
    cwd=$(printf '%s' "$input" | sed -n 's/.*"current_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -z "$cwd" ] && cwd="$PWD"
    short_cwd="${cwd/#$HOME/~}"
    printf "\033[0;35m%s\033[0m  \033[0;33m%s\033[0m  \033[2;37m(no jq — degraded statusline)\033[0m" \
        "$username" "$short_cwd"
}

command -v jq >/dev/null 2>&1 || { degraded_line; exit 0; }

# Single jq pass emits tab-separated fields so a malformed value can't
# bleed across columns. `// empty` returns empty strings rather than
# the literal "null"; cost defaults to 0 for the printf below.
IFS=$'\t' read -r model cwd used remaining cost < <(
    printf '%s' "$input" | jq -r '
        [
            (.model.display_name // "unknown model"),
            (.workspace.current_dir // .cwd // ""),
            (.context_window.used_percentage // empty | tostring),
            (.context_window.remaining_percentage // empty | tostring),
            (.cost.total_cost_usd // 0 | tostring)
        ] | @tsv
    ' 2>/dev/null
) || { degraded_line; exit 0; }

if [ -z "$model" ]; then
    degraded_line
    exit 0
fi

short_cwd="${cwd/#$HOME/~}"
username=$(whoami 2>/dev/null || echo "unknown")
cost_info=$(printf 'cost: $%.2f' "${cost:-0}")

if [ -n "$used" ] && [ -n "$remaining" ]; then
    # printf %.0f rounds half-away-from-zero, matching the old
    # int(round(...)) behaviour closely enough for a status line.
    context_info=$(printf 'ctx: %.0f%% used / %.0f%% left' "$used" "$remaining")
else
    context_info="ctx: new session"
fi

printf "\033[0;35m%s\033[0m  \033[0;36m%s\033[0m  \033[0;33m%s\033[0m  \033[0;32m%s\033[0m  \033[0;31m%s\033[0m" \
    "$username" "$model" "$short_cwd" "$context_info" "$cost_info"
