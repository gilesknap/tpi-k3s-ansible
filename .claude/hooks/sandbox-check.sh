#!/usr/bin/env bash
# UserPromptSubmit hook. Verifies the Claude sandbox is intact before
# every prompt. Exit 2 blocks the prompt and surfaces the message.
#
# Belt-and-suspenders against the "user invoked Claude via a non-shadow
# path" bypass — the bwrap launcher sets IS_SANDBOX=1, so an unset
# value means we are not in the sandbox.

fail() { echo "BLOCKED: $1" >&2; exit 2; }

[ "${IS_SANDBOX:-}" = "1" ] || \
    fail "IS_SANDBOX unset — Claude was launched outside the bwrap shadow. Run via /usr/local/bin/claude."

# Strict-under-/root: the host gitconfig must NOT be readable.
[ ! -e "$HOME/.gitconfig" ] || ! [ -s "$HOME/.gitconfig" ] || \
    fail "$HOME/.gitconfig is reachable — strict-under-/root inversion broken or the file mask regressed."

# Env scrub: tokens that may have been on the host shell must be empty.
[ -z "${GH_TOKEN:-}" ] || fail "GH_TOKEN is set inside the sandbox — --clearenv allowlist regressed."
[ -z "${GITHUB_TOKEN:-}" ] || fail "GITHUB_TOKEN is set inside the sandbox — --clearenv allowlist regressed."
[ -z "${ANTHROPIC_API_KEY:-}" ] || fail "ANTHROPIC_API_KEY is set inside the sandbox — --clearenv allowlist regressed."
[ -z "${SSH_AUTH_SOCK:-}" ] || fail "SSH_AUTH_SOCK is set inside the sandbox — --clearenv allowlist regressed."
[ -z "${DISPLAY:-}" ] || fail "DISPLAY is set inside the sandbox — --clearenv allowlist regressed."

# Curated gitconfig steering.
[ "${GIT_CONFIG_GLOBAL:-}" = "/etc/claude-gitconfig" ] || \
    fail "GIT_CONFIG_GLOBAL is '${GIT_CONFIG_GLOBAL:-<unset>}', not /etc/claude-gitconfig — git would fall back to the host gitconfig."
[ "${GIT_CONFIG_SYSTEM:-}" = "/dev/null" ] || \
    fail "GIT_CONFIG_SYSTEM is '${GIT_CONFIG_SYSTEM:-<unset>}', not /dev/null — git would read the host /etc/gitconfig."

# /run/secrets must be empty.
if [ -d /run/secrets ] && [ -n "$(ls -A /run/secrets 2>/dev/null)" ]; then
    fail "/run/secrets is non-empty — Docker/Compose secrets are reachable. tmpfs mask regressed."
fi

exit 0
