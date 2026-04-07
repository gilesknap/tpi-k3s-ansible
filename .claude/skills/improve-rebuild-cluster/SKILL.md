---
name: improve-rebuild-cluster
description: Iteratively simplify the rebuild-cluster skill — automate manual steps, shrink the skill, ship each fix as a PR into a working branch.
user-invocable: true
---

# Improve Rebuild Cluster

Iteratively simplify the `rebuild-cluster` skill by automating manual
steps. Runs autonomously through the entire convergence checklist,
shipping each fix as a separate PR into a working branch.

## North Star

The rebuild skill should converge on `docs/how-to/bootstrap-cluster.md`.
Every manual step not in that doc is a gap to automate away. Success =
the rebuild skill gets shorter each iteration.

## Rules

- Fixes go into automation (ansible/helm/just), not more docs
- The rebuild skill must get shorter or simpler, never longer
- Reference GitHub issues when fixes address them
- Use `uv run` for commits, `SSH_AUTH_SOCK="/tmp/ssh-agent.sock"` for ansible
- Read CLAUDE.md before starting -- it has hard rules and foot-guns
- **Work autonomously** -- iterate through all checklist items without
  pausing for user input. Only stop if blocked or if a fix would be
  destructive to the live cluster.

## Branch Strategy

All improvements land on a single **working branch** (`improve-rebuild-skill`)
that collects every fix. Each fix gets its own feature branch and PR
targeting the working branch (not `main`).

```
main
 └── improve-rebuild-skill          ← working branch (PRs merge here)
      ├── improve-rebuild-<fix-1>   ← feature branch → PR into working
      ├── improve-rebuild-<fix-2>
      └── ...
```

At the end the user reviews all closed PRs and merges
`improve-rebuild-skill` → `main` in one go.

### Setup (first invocation only)

```bash
git checkout main && git pull
git checkout -b improve-rebuild-skill
git push -u origin improve-rebuild-skill
```

If `improve-rebuild-skill` already exists, check it out and pull.
Retarget any existing PRs that point at `main` to `improve-rebuild-skill`.

## Iteration Loop

The **orchestrator** (this skill's top-level context) picks the next
item from the checklist and delegates each fix to a **subagent**. This
keeps the main context small — each subagent starts fresh, does the
work, and returns a summary.

### Orchestrator loop

For each `todo` item in priority order:

1. Read the convergence checklist to pick the next item
2. Record the current rebuild-skill line count (`wc -l`)
3. Launch a **general-purpose Agent** (not Explore) with `mode: "auto"`
   and a prompt containing:
   - Which checklist item to fix (number, description, target)
   - The branch strategy: branch from `improve-rebuild-skill`, PR back
   - The rules from this skill (uv run, SSH_AUTH_SOCK, CLAUDE.md, etc.)
   - Instructions to: implement fix → verify on cluster → shrink
     rebuild skill → commit → push → create PR targeting
     `improve-rebuild-skill` → merge the PR (`gh pr merge --squash`)
   - Instruction to return: what changed, PR number, new line count,
     any blockers or new issues discovered
4. When the subagent returns:
   - Pull the working branch to get the merged changes
   - Update the convergence checklist (mark `done` + date)
   - Commit the checklist update directly to `improve-rebuild-skill`
   - If blocked: note the reason and continue to next item
5. Repeat for the next `todo` item

### Subagent prompt template

```
You are improving the rebuild-cluster skill in /workspaces/tpi-k3s-ansible.

## Task
Fix checklist item #{N}: {description}
Target: {target}
{GitHub issue reference if any}

## Branch strategy
1. git checkout improve-rebuild-skill && git pull
2. git checkout -b improve-rebuild-{short-name}
3. Do the work (see below)
4. uv run git commit (reference issue if applicable)
5. git push -u origin improve-rebuild-{short-name}
6. Create PR targeting improve-rebuild-skill (not main)
   Use: gh pr create --base improve-rebuild-skill --title "..." --body "..."
   IMPORTANT: gh pr edit fails on this repo (classic projects bug).
   Use gh api for edits: gh api repos/gilesknap/tpi-k3s-ansible/pulls/N -X PATCH -f ...
7. Merge: gh pr merge --squash
8. Return: what changed, PR URL, rebuild skill line count (wc -l),
   any blockers or new issues discovered

## Rules
- Read CLAUDE.md before starting — hard rules and foot-guns
- Use uv run for all git commits (pre-commit hooks need uv venv)
- Use SSH_AUTH_SOCK="/tmp/ssh-agent.sock" for all ansible commands
- Never mutate ArgoCD-managed resources directly
- Fixes go into automation (ansible/helm/just), not docs
- The rebuild skill must get shorter or simpler, never longer
- After implementing the fix, verify it against the live cluster
- Then edit .claude/skills/rebuild-cluster/SKILL.md to remove/simplify
  the manual steps that the fix automated away

## What to fix
{Specific guidance for this checklist item — research the target area,
describe what needs to change and where}
```

## Wrap-up

After all iterations complete (or all remaining items are blocked):

1. Run `/memo` to capture what changed
2. Report to user:
   - Summary table of all PRs shipped
   - Total skill line count change (start → end)
   - Any items skipped and why
   - Any new manual steps discovered
3. The user reviews closed PRs, then merges
   `improve-rebuild-skill` → `main`

## Convergence Checklist

| # | Manual Step | Status | Issue | Target |
|---|------------|--------|-------|--------|
| 1 | Sealed-secrets CRD not ready on first run (`ignore_errors`) | done 2026-04-07 | #247 | ansible role wait loop |
| 2 | Dex ConfigMap patch separate from Helm install | todo | #245 | move into Helm values |
| 3 | `seal-argocd-dex` is interactive (prompts for GitHub creds) | done 2026-04-07 | #256 | accept env vars |
| 4 | `set-admin-password` is interactive | done 2026-04-07 | #256 | accept env var |
| 5 | Manual `just seal` for each remaining secret | todo | -- | batch seal recipe or ansible task |
| 6 | Prometheus admission secret manual creation | todo | -- | ansible post-task |
| 7 | GPU node separate playbook run + pod deletion | todo | -- | playbook ordering or role |
| 8 | Branch management (edit/revert repo_branch) | todo | -- | `--extra-vars` |
| 9 | Two playbook runs (initial + post-seal) | todo | #247+#245 | single run after 1+2 fixed |
| 11 | Secret extraction script generated each time | todo | -- | committed script |

## Priority Order

1. **#247** (sealed-secrets wait) -- foundation fix, unblocks single-run goal
2. **Non-interactive just recipes** -- enables full automation of secret sealing
3. **#245** (dex.config in Helm) -- eliminates ConfigMap patch + second playbook run
4. **Prometheus admission secret** -- automate in ansible
5. **GPU node ordering** -- run servers before cluster or add to sequence
6. **Branch management** -- use `--extra-vars repo_branch=X`
