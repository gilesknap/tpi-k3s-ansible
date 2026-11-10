#!/usr/bin/env bash
# Shared secret prompt for the Cloudflare scripts. Source from bash:
#   . "$(dirname "$0")/lib/cf-secrets.sh"

# read_secret VAR FILE PROMPT: print the value of $VAR, else FILE's
# contents, else what the user types (not echoed).
read_secret() {
    local value=${!1:-}
    if [[ -z $value && -n $2 && -r $2 ]]; then
        value=$(<"$2")
    fi
    if [[ -z $value ]]; then
        read -rsp "$3: " value </dev/tty
        echo >&2
    fi
    [[ -n $value ]] || { echo "ERROR: no value for $1" >&2; exit 1; }
    printf '%s' "$value"
}
