# claude-sandbox recipes. Shipped verbatim into promoted targets via
# `just promote`, so every recipe here must be useful in both the
# source clone and a promoted host workspace.

# Seed the sandbox's curated `.claude/` (commands, skills, hooks,
# statusline, sandbox-check hook) into a target host workspace. See
# .devcontainer/claude-sandbox/promote.sh for the rationale.
promote target=invocation_directory():
    bash .devcontainer/claude-sandbox/promote.sh {{ target }}

# Authenticate gh CLI with a GitHub PAT (token not stored in shell history).
gh-auth:
    #!/usr/bin/env bash
    url=$'\e[4;36mhttps://github.com/settings/personal-access-tokens\e[0m'
    cat <<EOF
    Create or renew a fine-grained PAT at:
      $url

    Recommended settings for a sandboxed Claude Code:
      - Resource owner: your user (or org that owns this repo)
      - Repository access: Only select repositories -> just this repo
      - Expiration: short (e.g. 30 days) so a leaked token expires quickly
      - Repository permissions (Read and Write):
          Contents, Issues, Pull requests
        (Metadata: Read-only is added automatically)
      - Leave everything else unset / no access

    EOF
    read -sp "GitHub PAT: " t && echo
    echo "$t" | gh auth login --with-token
    unset t
    gh auth setup-git
    gh auth status

# Authenticate glab CLI with a GitLab PAT (token not stored in shell history).
# --git-protocol https prevents glab's SSH insteadOf rewrite.
glab-auth hostname="gitlab.com":
    #!/usr/bin/env bash
    url=$'\e[4;36mhttps://gitlab.com/-/user_settings/personal_access_tokens\e[0m'
    cat <<EOF
    Create or renew a fine-grained PAT at:
      $url
      (or your organisation's GitLab instance equivalent)

    Recommended scopes for a sandboxed Claude Code:
      - api, read_repository, write_repository
      - Short expiration so a leaked token expires quickly

    EOF
    read -sp "GitLab PAT for {{ hostname }}: " t && echo
    echo "$t" | glab auth login --stdin --hostname {{ hostname }} --git-protocol https
    unset t
    glab auth status
