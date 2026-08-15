# Using Claude Code

This project includes [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
configuration for AI-assisted development with safe autonomy guardrails.

## Sandbox installation

The sandbox is [claude-sandbox](https://github.com/DiamondLightSource/claude-sandbox),
installed from its upstream release by `.devcontainer/postCreate.sh` — no
sandbox code is vendored into this repo. The installer picks the newest
release tag, so a devcontainer rebuild also brings the sandbox up to date;
`claude-sandbox version` reports what is installed and `claude-sandbox update`
upgrades between rebuilds.

The installer places a shadow `claude` on `$PATH` that wraps the real binary
in `bwrap`, plus a global integrity guard (installed to `/etc`, so a session
cannot edit it away) that fails closed if Claude is ever launched unwrapped.
Run `claude-sandbox verify` for the live PASS/FAIL battery.

Two pieces of wiring are this repo's, because an installer cannot supply them:

`--device=/dev/net/tun` in `devcontainer.json`'s `runArgs`
: Required by the fail-closed network egress jail. Without it, `claude`
  refuses to launch.

`.devcontainer/claude-sandbox.conf`
: Copied to `/etc/claude-sandbox.conf` by `postCreate.sh` after the install.
  It widens the writable bind to `/workspaces` (peer projects) plus `/cache`,
  and lists each cluster host as an `allow-ip` — the egress jail blackholes
  RFC1918 by default, so ansible, `ssh` and `kubectl` would otherwise fail
  from inside the sandbox. Keep the list in step with `hosts.yml`, and
  re-apply with `just sandbox-conf` after a `claude-sandbox update`.

## Credential isolation

The devcontainer applies several layers of protection against prompt injection
attacks (malicious instructions hidden in GitHub issues, web content, or
repository files that attempt to misuse Claude's tool access):

**Sandbox-enforced isolation from host credentials:**
: Claude runs inside a bwrap sandbox that uses `--clearenv` and a
  strict-under-`/root` tmpfs overlay. Only an
  explicit allowlist of dotfiles is bind-mounted back into the sandbox —
  `.ssh` is deliberately excluded, and `SSH_AUTH_SOCK` is not re-exported.
  So even though VS Code forwards the host SSH agent to the devcontainer
  (for use in your own terminals), Claude cannot reach it. The same boundary
  applies to `~/.netrc`, `~/.Xauthority`, `/etc/shadow`, and the rest of
  `$HOME`'s contents.

**Git credential helper blanking:**
: `postStartCommand` runs `git config --global credential.helper ''`, which
  overrides any credential helper injected by VS Code's Dev Containers
  extension. Remote pushes require an explicit fine-grained PAT via
  `gh auth login` + `gh auth setup-git`.

**Scoped GitHub authentication:**
: GitHub CLI auth is persisted in a per-repo container volume
  (`gh-auth-${localWorkspaceFolderBasename}`). Use a fine-grained PAT scoped
  to only the repositories needed, rather than a broad OAuth token. The volume
  isolation means each project gets its own credential scope.

## Permission tiers

`.claude/settings.json` defines three permission tiers:

**Allow** — runs without confirmation:
: File operations (Read, Edit, Write), bash commands, web search/fetch.

**Prompt** — asks for confirmation each time:
: Force push (`git push --force`), hard reset (`git reset --hard`), and
  network escape vectors (`ssh`, `scp`, `rsync`, `sftp`, `wget --post*`,
  `telnet`, `mail`, `sendmail`).

**Deny** — blocked entirely:
: Nothing is denied by default. Move commands here if you want to hard-block them.

## CLAUDE.md

The `CLAUDE.md` file at the repo root provides project-specific guidance to AI
agents. It captures the hard rules (never mutate the live cluster, never commit
to `main`, protected data paths), conventions, key file paths, and pointers to
on-demand skills. Read it directly for the current set — it changes as the
project evolves.

## Workflow

1. On the host, make sure your ansible key is loaded into a running
   `ssh-agent` before opening the container. VS Code will forward
   `SSH_AUTH_SOCK` and copy `~/.ssh/known_hosts` into the devcontainer
   automatically.
2. Open the repo in the devcontainer (tools are installed automatically)
3. Set up GitHub CLI auth: `claude-sandbox gh-auth` (use a fine-grained PAT),
   or `just setup` to check the SSH agent at the same time
4. Launch Claude Code from the VS Code extension or CLI
5. The agent reads `CLAUDE.md` and `.claude/settings.json` on startup
6. Safe read-only commands run automatically; infrastructure changes prompt
   for approval

## Customising permissions

Edit `.claude/settings.json` to adjust. Move entries between `allow`, `prompt`,
and `deny` lists as needed. Patterns use glob syntax — `Bash(kubectl get *)`
matches any `kubectl get` command.
