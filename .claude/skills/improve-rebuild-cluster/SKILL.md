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

Repeat for each `todo` item in the convergence checklist, in priority
order. Each iteration follows steps 1–6 below, then loops back to
step 1 for the next item.

### Step 1: Assess

Read the convergence checklist. Pick the next `todo` item by priority.
Use Explore agents if you need to research the target area.

### Step 2: Branch and Fix

```bash
git checkout improve-rebuild-skill && git pull
git checkout -b improve-rebuild-<description>
```

Implement the fix in the appropriate layer:
- **Ansible role** -- ordering/wait/automation
- **Helm values** -- config consolidation
- **Justfile recipe** -- make interactive recipes accept env vars/args
- **Script** -- new automation

### Step 3: Verify the Fix

Run the relevant portion against the live cluster:
- Ansible: `SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_all.yml --tags <tag>`
- Just recipes: run the recipe and check output

**Inner loop** -- iterate until it passes.

### Step 4: Shrink the Skill

1. Edit `.claude/skills/rebuild-cluster/SKILL.md` -- remove or simplify
   the steps that the fix automated away
2. If the fix also simplifies a how-to doc, simplify that too
3. The skill should get measurably shorter (fewer lines, fewer manual steps)

### Step 5: Ship

1. `uv run git commit` -- reference GitHub issue if applicable
2. Update the convergence checklist below (mark item `done`, add date)
3. Push and create PR **targeting `improve-rebuild-skill`**
4. Merge the PR immediately (`gh pr merge --squash`)
5. Note: line count before/after for the final report

### Step 6: Loop or Finish

- More `todo` items remain → go to Step 1
- All items `done` → proceed to Wrap-up
- Blocked on an item → skip it, note why, continue to next

## Wrap-up

After all iterations complete:

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
| 3 | `seal-argocd-dex` is interactive (prompts for GitHub creds) | todo | -- | accept env vars |
| 4 | `set-admin-password` is interactive | todo | -- | accept env var |
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
