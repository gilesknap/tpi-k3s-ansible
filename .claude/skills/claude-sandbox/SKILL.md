---
name: claude-sandbox
description: Architecture decisions and historical reversals for this repo's bwrap-based Claude sandbox. Covers real claude off PATH, container-scoped PATs, Ubuntu-24.04 CI bwrap workarounds, dogfood ≈ guest, the `just promote` three-layer model (no JSONC editing), and two walked-back paths (Python orchestration; embedding in python-copier-template). Surface before edits to `.devcontainer/claude-sandbox/{claude-shadow,install.sh,promote.sh}`, `install`, `tests/`, `.github/workflows/ci.yml`, or `.claude/commands/verify-sandbox.md`; or before any suggestion to re-introduce Python tooling, embed in python-copier-template, persist gh/glab PATs across containers, or auto-edit JSONC devcontainer.json.
---

# claude-sandbox

Project-specific architecture decisions. The code documents *what*;
this skill documents *why* and *what regressions to refuse*. Threat
model: `README-CLAUDE.md`; live verification: `/verify-sandbox`
(`.claude/commands/verify-sandbox.md`).

## Invariant 1 — plain `claude` MUST resolve to the shadow

Anthropic's `curl install.sh` drops the real binary at
`~/.local/bin/claude` AND prepends `$HOME/.local/bin` to the user's
shell rc. After the next shell, `which claude` resolves past the
bwrap shadow at `/usr/local/bin/claude` → **sandbox escape via
plain `claude`**.

`install_claude_binary` fixes this by relocating the real binary to
`/usr/libexec/claude-sandbox/claude` (off the user's PATH). The
shadow binds it back to `~/.local/bin/claude` *inside* the sandbox
so Claude's `installMethod=native` self-check still sees the
conventional path.

**Refuse as regressions:**
- Any "simplification" that skips the relocate-after-curl step.
- Removing the unconditional bind-back of `~/.local/bin/claude`
  inside the sandbox — the dest is created on the in-sandbox tmpfs
  `$HOME`, so don't gate it on the host file existing.
- `tests/bwrap_argv.sh` scenarios 1 & 4a guard the bind pair; update
  both if you change the bind.

**Acceptable swap:** if Anthropic adds `--no-modify-path`, drop the
relocate — provided plain `claude` still cannot resolve past
`/usr/local/bin/claude`.

## Invariant 2 — PATs are container-scoped; `just gh-auth` per rebuild is deliberate

The re-paste-on-rebuild ceremony for `gh` / `glab` PATs is the cost
of keeping blast radius small: fine-grained PATs typically cover
multiple repos, so any path mounted across devcontainers would let
a compromised session reach every repo the PAT touches.

`~/.claude` and `~/.claude.json` *are* cross-container (via
`link_terminal_config` symlinks) because they hold one Claude login,
not repo-scoped credentials. Don't conflate the two.

**Refuse as regressions:**
- New persistent-credential mounts (volume, bind, anywhere) for
  `gh` or `glab` PATs.
- Re-purposing the (currently deleted) `/cache` Docker volume for
  tokens. Restoring `/cache` for *caches* is fine; for tokens, not.

If a future request says "stop re-pasting the PAT" — surface this
tradeoff before implementing the shortcut.

## Invariant 3 — bwrap on Ubuntu 24.04 GitHub runners needs three workarounds

`ubuntu-latest` ships configured in ways that break bwrap. The
failure modes cascade in this order:

1. **`setting up uid map: Permission denied`** —
   `kernel.apparmor_restrict_unprivileged_userns=1` is the runner
   default. Relax the sysctl and install an unconfined AppArmor
   profile for `/usr/bin/bwrap`.
2. **`/run/secrets` doesn't exist** — sandbox does
   `--tmpfs /run/secrets`; `sudo mkdir -p /run/secrets` first.
3. **`$GITHUB_WORKSPACE` lives under `$HOME=/home/runner`** —
   path-positional checks that assert "$HOME contains only X" trip
   on the workspace bind. `export HOME=/tmp/sandbox-home` before
   the bwrap step (+ `mkdir -p "$HOME/.claude" "$HOME/.cache"`).

All three are required, in order. `.github/workflows/ci.yml` applies
them — five push-and-iterate cycles to land this; don't re-discover.

## Design principle — keep dogfood ≈ guest

The repo's own devcontainer (dogfood) and a `git clone + ./install`
inside any other devcontainer (guest) should go through the same
setup path. Prefer `install.sh` over `devcontainer.json` /
`postCreate.sh` / `initializeCommand.sh` when a fix can live in
either — guest devcontainers then get it for free, and the audit
surface stays single-track.

Sample: per-file binds for `/root/.claude{,.json}` were dropped once
`link_terminal_config` covered both paths uniformly; only the shared
`/user-terminal-config` bind remains in `devcontainer.json`.

**Refuse as regressions:** dogfood-only `postCreate` /
`initializeCommand` work, or `devcontainer.json` mounts that could
have been done in `install.sh`. Ask "would this work for a
clone+install inside an unrelated devcontainer?" — if not, push it
into `install.sh`.

## Design principle — `just promote` does three layers, never edits JSONC

`just promote <target>` (PR #20, issue #18) makes a target workspace
a self-sufficient claude-sandbox host:

1. **Curated `.claude/`** — commands, skills, hooks, statusline,
   plus `wire_settings_{hook,statusline}` against the target's
   `settings.json`.
2. **Install machinery** — `.devcontainer/claude-sandbox/{install.sh,
   claude-shadow, promote.sh}` + root `justfile`. The justfile is
   shipped verbatim, so its recipes must all be promote-target-safe;
   source-repo-only recipes (`test`, `upgrade`, `verify`) were dropped
   for this reason. The root `install` shim is *not* copied; it's the
   source repo's manual-UX entry (`./install`), not a target workflow.
3. **`.devcontainer/postCreate.sh`** running
   `bash .devcontainer/claude-sandbox/install.sh` (created if absent,
   idempotently appended otherwise). Promote then prints a one-line
   `postCreateCommand` snippet for the user to paste into
   `devcontainer.json` — we do **not** edit it.

**Refuse as a regression**: auto-editing `devcontainer.json`. It's
JSONC in the wild and comment-preserving structured edits need
either ~50 lines of awk (string/block-comment state-tracking) or a
node/python lib dependency — both rejected in PR #20. The user knows
whether they've wired the line or need to chain it. "Strip and
re-insert comments" isn't simpler either — re-insert needs stable
anchors that survive the edit. Print the snippet; trust them.

**Two intentional don't-update edges in re-promote** — the only
gaps in the "re-promote = full sync" mental model:

- `wire_settings_statusline` is *create-if-absent*. An existing
  `.statusLine` (ours or the user's) is left alone.
- `wire_postcreate_script` only checks whether `bash install` is on
  any line of `postCreate.sh`. The file body is never rewritten if
  the file exists.

Everything else propagates via `install_file`'s `cmp -s`
overwrite-on-diff.

**Source-guard pattern**: `install.sh` ends with
`[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"` so `promote.sh` can
`source install.sh` to reuse `install_file` + `wire_settings_*`
without re-running `main`. Don't remove the guard.

## Historical reversals — raise before re-treading

Two paths walked back. If a change suggests either, surface the
history and re-justify against the underlying principle — **the
sandbox's surface must stay small enough to audit in one read** —
before proceeding.

### Reversal 1 — Python orchestration

Trajectory: `embedded bash → standalone bash → Python package + typer
CLI → bash-only` (commits `25e67ce`, `a35b8ee`, then `bf65407`
"feat: bash-only rewrite — drop Python package, self-contained
shadow", 2026-05-12, issue #14 / PR #15).

The tool is fundamentally one bash function building a bwrap argv.
A ~110 KB Python package (pyproject, uv lockfile, pytest scaffolding,
37 unit tests, typer CLI) made the security-critical bits harder to
audit across multiple modules. Bash-only is ~80 lines shadow + ~80
lines installer.

**Refuse without justification:**
- "Let's add a small Python CLI for nicer error messages / config /
  arg parsing."
- "Let's bring back pytest / uv / a `src/` package — it's only a
  little code."
- Anything that re-introduces `pyproject.toml`, `uv.lock`,
  `src/claude_sandbox/`, or `test_*.py`.

Root `CLAUDE.md` says "Bash-only. No Python package, no uv, no
pytest — don't add them back." This skill explains the why.

### Reversal 2 — extracted from python-copier-template

The sandbox originally lived embedded in `python-copier-template` as
`.devcontainer/claude-sandbox.sh` (a single bash script using
`unshare -m` + tmpfs overlays). Extracted because:

- A security tool needs **one canonical, audit-friendly home**, not
  a templated copy in every project.
- The bwrap-based defences (`--cap-drop ALL`, `--clearenv`
  allow-list, strict-under-`/root` inversion, `NO_NEW_PRIVS`, …)
  replace the older `unshare -m` and would be awkward inside a
  per-project template.
- A standalone repo gets a versioned release surface, its own CI,
  and `/verify-sandbox` as a first-class command.

`/workspaces/python-copier-template/.devcontainer/claude-sandbox.sh`
exists as prior art but is **not** maintained.

**Refuse without justification:**
- Adding a `template/` directory or `copier.yml`.
- "Let's keep a copy synced into python-copier-template" — the
  template should *consume* this repo, not embed it.

## Diagnostic discipline — silent in-sandbox check failures

When a check inside the sandbox fails silently (subprocess swallows
stdout/stderr), inject a debug `INNER` step that runs the same body
verbatim and prints its output *before* exec'ing the real verifier.
The original Check 03 silent failure was unsolvable until we printed
`extras` directly — `--bind-try /dev/null` masks themselves create
entries under `$HOME` (the spec hadn't whitelisted them). One
`printf` beats hours of guessing from outside.

## Diagnostic discipline — bind-mount vs runtime tmpfs write

When unexpected entries appear inside the sandbox (typically under
`$HOME` or `$HOME/.config`), **first determine whether they're a
host bind-mount leak or a sandboxed-process tmpfs write**. The
remediations are completely different.

```bash
# Bind from the host?
grep " /root/.config/<thing> " /proc/self/mountinfo
# stat -c '%D' compares device IDs — tmpfs entries share /root's dev.
stat -c '%n: dev=%D inode=%i' /root /root/.config/<thing>
```

No mountinfo entry + same `dev` as `/root` → tmpfs write by
sandboxed code (a feature self-registering). Fix upstream by
disabling the feature, not by widening the allow-list. Mountinfo
entry → genuine inversion leak; tighten the bwrap argv.

Concrete miss (2026-05): Chrome `NativeMessagingHosts` dirs under
`~/.config/` — initially flagged as a bind leak; mountinfo showed
no bind. It was Claude Code's startup write registering the browser
extension. Fix: `--no-chrome` injection in the shadow, check 03
stayed strict.

## Where things live

| Concern                       | File                                                |
|-------------------------------|-----------------------------------------------------|
| bwrap argv construction       | `.devcontainer/claude-sandbox/claude-shadow`        |
| Installer (relocate + wire)   | `.devcontainer/claude-sandbox/install.sh`           |
| Promote orchestrator          | `.devcontainer/claude-sandbox/promote.sh`           |
| Root-shim installer entry     | `install`                                           |
| bwrap argv unit tests         | `tests/bwrap_argv.sh`                               |
| End-to-end install smoke test | `tests/smoke.sh`                                    |
| Promote smoke test            | `tests/promote.sh`                                  |
| CI workflow                   | `.github/workflows/ci.yml`                          |
| Live verification spec        | `.claude/commands/verify-sandbox.md`                |
| Pre-prompt gate hook          | `.claude/hooks/sandbox-check.sh`                    |
| Threat model + binds rationale| `README-CLAUDE.md`                                  |
| Recipes (promote, gh-auth, …) | `justfile` (shipped verbatim by `just promote`)     |

Touching any of these → re-read this skill first.
