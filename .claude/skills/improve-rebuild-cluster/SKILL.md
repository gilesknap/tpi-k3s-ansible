---
name: improve-rebuild-cluster
description: Iteratively run rebuild-cluster, fix what breaks, push complexity into automation, shrink the skill and docs. One improvement per invocation.
user-invocable: true
---

# Improve Rebuild Cluster

Iteratively simplify the `rebuild-cluster` skill by automating manual
steps. Each invocation fixes one thing, verifies it with a full rebuild,
and ships the improvement.

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

## Phase 1: Assess

This skill runs from a clean context. Gather all state first.

**Launch up to 3 Explore agents in parallel:**
- Agent 1: Read CLAUDE.md + MEMORY.md + this skill's convergence checklist
- Agent 2: Read the rebuild-cluster skill, count manual intervention points and lines
- Agent 3: Check `gh issue list --state open` for issues that eliminate manual steps

Then synthesize findings:
1. Check which checklist items are `done` vs `todo`
2. Pick the highest-impact `todo` item: blocks other fixes > most frequent > has clear GitHub issue
3. Present the pick and approach to the user before proceeding

## Phase 2: Branch and Fix

```bash
git checkout main && git pull && git checkout -b improve-rebuild-<description>
```

Implement the fix in the appropriate layer:
- **Ansible role** -- ordering/wait/automation (e.g. #247 sealed-secrets wait)
- **Helm values** -- config consolidation (e.g. #245 dex.config into Helm)
- **Justfile recipe** -- make interactive recipes accept env vars/args
- **Script** -- new automation (e.g. batch secret sealing)

Use Explore agents to research the target area while planning the fix.
For independent changes in different files, use parallel general-purpose
agents in worktrees.

## Phase 3: Verify the Fix

Run the relevant portion of the rebuild to confirm the fix works:
- Ansible: `SSH_AUTH_SOCK="/tmp/ssh-agent.sock" ansible-playbook pb_all.yml --tags <tag>`
- Just recipes: run the recipe and check output

**Inner loop** -- iterate until it passes. Do not move on until verified
against the live cluster.

## Phase 4: Shrink the Skill

1. Edit `.claude/skills/rebuild-cluster/SKILL.md` -- remove or simplify
   the steps that the fix automated away
2. If the fix also simplifies a how-to doc, simplify that too
3. The skill should get measurably shorter (fewer lines, fewer manual steps)

## Phase 5: Full Validation

Run `/rebuild-cluster` end-to-end to verify the improvement works in
the full rebuild context. **This phase is mandatory.**

- Fix breaks related to the change: go back to Phase 2
- Note unrelated breaks for the next iteration (add to checklist)
- If rebuild passes: proceed to Phase 6

Delegate Phase 7 browser verification to a subagent (it generates
huge context from screenshots). Use background agents for health
monitoring during post-rebuild steps.

## Phase 6: Ship

1. `uv run git commit` -- reference GitHub issue if applicable
2. Update the convergence checklist below (mark item `done`, add date)
3. Push and create PR
4. Run `/memo` to capture what changed
5. Report to user:
   - What was automated
   - How much shorter the rebuild skill got (line count before/after)
   - What the next highest-priority item is
   - Any new manual steps discovered

## Phase 7: Next Iteration

Check the convergence checklist:
- Remaining `todo` items: suggest running `/improve-rebuild-cluster` again
- All `done`: report completion
- New items discovered: add to checklist and note them

Each invocation handles one improvement. Run again for the next one.

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
