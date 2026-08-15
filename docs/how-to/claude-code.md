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

  It also binds back the three `/root` paths this repo's tooling lives in.
  The sandbox wipes `$HOME` to a tmpfs and restores only its own allowlist,
  which does not include them:

  | Path | Why |
  | --- | --- |
  | `/root/bin` | `bin_dir` — where the `tools` role installs `kubectl`, `helm`, `kubeseal`, `argocd`. The `/usr/local/bin` entries are symlinks into it, so without the bind they dangle and the CLIs are "not found" despite appearing to exist |
  | `/root/.kube` | The kubeconfig, so a visible `kubectl` has a cluster to talk to |
  | `/root/.config/claude-ssh` | Claude's own ansible-account key from `just claude-ssh-bootstrap`; `$HOME/.config` is a strict allowlist upstream (`gh` + `glab` only) |

  Symptom when these are missing: `kubectl` reports `command not found`
  inside the sandbox while resolving fine in an ordinary devcontainer
  terminal.

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

## Permissions

This repo ships **no committed permission policy**. What is checked in under
`.claude/` is the agent toolkit only — the workspace commands in
`.claude/commands/` and the on-demand skills in `.claude/skills/`. Tool
approvals are per-developer and accumulate in `.claude/settings.local.json`,
which is gitignored, so your allowlist is yours and never lands in a PR.

Containment comes from two other places instead:

**The sandbox**
: The bwrap jail and its fail-closed egress filter (see above). This is the
  hard boundary — it holds whatever a session has approved, because it is
  enforced outside the agent rather than by it.

**`CLAUDE.md`**
: The hard rules — never mutate the live cluster, never commit to `main`,
  protected data paths. These are conventions the agent follows, not
  enforcement, so treat them as guidance rather than a guarantee.

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
5. The agent reads `CLAUDE.md` and the `.claude/` toolkit on startup
6. Approve tools as they are requested; the answers persist in
   `.claude/settings.local.json` for subsequent sessions

## Customising permissions

Edit `.claude/settings.local.json` to adjust your own approvals — move entries
between the `allow`, `ask`, and `deny` lists under `permissions`. Patterns use
glob syntax, so `Bash(kubectl get *)` matches any `kubectl get` command.

To impose a policy on everyone working in the repo rather than just yourself,
put the same `permissions` block in a committed `.claude/settings.json`. Both
files are merged with your user-global `~/.claude/settings.json`, with the
more specific file winning.
