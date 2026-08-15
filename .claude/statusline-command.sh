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

# Single jq pass emits unit-separator (\x1f) delimited fields so a
# malformed value can't bleed across columns. We can't use \t: `read`
# treats tab as IFS-whitespace and collapses runs of it, so an empty
# field (e.g. absent .effort.level) would silently shift every later
# column. \x1f is non-whitespace, so empty fields are preserved.
# `// ""` yields empty strings rather than the literal "null"; cost
# defaults to 0 for the printf below.
IFS=$'\x1f' read -r model effort cwd used remaining cost < <(
    printf '%s' "$input" | jq -r '
        [
            (.model.display_name // "unknown model"),
            (.effort.level // ""),
            (.workspace.current_dir // .cwd // ""),
            (.context_window.used_percentage // "" | tostring),
            (.context_window.remaining_percentage // "" | tostring),
            (.cost.total_cost_usd // 0 | tostring)
        ] | join("")
    ' 2>/dev/null
) || { degraded_line; exit 0; }

if [ -z "$model" ]; then
    degraded_line
    exit 0
fi

short_cwd="${cwd/#$HOME/~}"
username=$(whoami 2>/dev/null || echo "unknown")
# Subscription usage is billed at a flat rate; total_cost_usd is what the
# same tokens would have cost on the metered API, so label it as such.
cost_info=$(printf 'equiv API cost: $%.2f' "${cost:-0}")

# The status payload has no branch field, so derive it from cwd. Use the
# plumbing form so a detached HEAD or non-repo cwd just yields an empty
# branch (column omitted) rather than noise on stderr.
branch=$(git -C "${cwd:-$PWD}" symbolic-ref --quiet --short HEAD 2>/dev/null)

# Effort level is only present for models that support it; suffix it to
# the model column (e.g. "Opus 4.8 · high") when available.
if [ -n "$effort" ]; then
    model="$model · $effort"
fi

if [ -n "$used" ]; then
    # printf %.0f rounds half-away-from-zero, matching the old
    # int(round(...)) behaviour closely enough for a status line.
    # "% used" implies the remainder, so we drop the redundant "left".
    context_info=$(printf 'ctx: %.0f%% used' "$used")
else
    context_info="ctx: new session"
fi

branch_info=""
[ -n "$branch" ] && branch_info=$(printf "  \033[0;35mgit:%s\033[0m" "$branch")

printf "\033[0;35m%s\033[0m  \033[0;36m%s\033[0m  \033[0;33m%s\033[0m%s  \033[0;32m%s\033[0m  \033[0;31m%s\033[0m" \
    "$username" "$model" "$short_cwd" "$branch_info" "$context_info" "$cost_info"
