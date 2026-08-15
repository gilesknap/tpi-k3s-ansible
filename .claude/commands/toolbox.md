---
description: List the commands and skills available from BOTH the user-global ~/.claude/ toolkit AND the current workspace's .claude/ overrides (fast, hardcoded — refresh with /toolbox-update).
---

Output exactly the following text verbatim, with no preamble, commentary, or trailing summary. The two sections below correspond to the two directories Claude actually has access to: the user-global `~/.claude/` toolkit and the current workspace's `.claude/` overrides. If a name appears in both, the workspace copy wins for the running Claude (it's loaded later); both are listed here so you can see what's available at each scope.

**User-global commands (`~/.claude/commands/`)**
- `/grill-me` — Interview me relentlessly to stress-test a plan or design.
- `/to-issues` — Break a plan/PRD into independently-grabbable issues using tracer-bullet vertical slices.
- `/to-prd` — Turn the current conversation context into a PRD and publish it to the issue tracker.
- `/toolbox` — List the user-scoped commands and skills in ~/.claude.
- `/toolbox-update` — Rescan ~/.claude and the workspace .claude and refresh the hardcoded list inside /toolbox.
- `/write-a-skill` — Create a new agent skill with proper structure and progressive disclosure.
- `/zoom-out` — Zoom out and give a higher-level map of the surrounding code.

**User-global skills (`~/.claude/skills/`)**
- `/diagnose` — Disciplined diagnosis loop for hard bugs and performance regressions.
- `/grill-with-docs` — Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation inline as decisions crystallise.
- `/improve-codebase-architecture` — Find deepening opportunities in a codebase, informed by the domain language in CONTEXT.md and the decisions in docs/adr/.
- `/tdd` — Test-driven development with red-green-refactor loop.
- `/triage` — Triage issues through a state machine driven by triage roles.

**Workspace commands (`./.claude/commands/`)**
- `/add-node` — Add a new node to the cluster.
- `/bootstrap-cluster` — Bootstrap the cluster from scratch.
- `/memo` — Save task state to auto-memory, promote reusable lessons to skills.
- `/pr-squash` — Tidy a PR's commit history before merging.
- `/rebuild-cluster` — Full teardown and rebuild, including PR-branch testing.
- `/test-oauth-flow` — Drive an OAuth login end to end against a cluster service.
- (plus workspace copies of the user-global commands listed above)

**Workspace skills (`./.claude/skills/`)**
- `/ansible` — Playbook structure, tags, topology rules, and operational foot-guns.
- `/argocd` — ArgoCD operations, branch repointing, OCI chart wiring foot-guns.
- `/cloudflare` — Cloudflare Tunnel and Access configuration for exposed services.
- `/oauth` — oauth2-proxy setup, configuration, and troubleshooting.
- `/rkllama` — RKLLama NPU LLM server operations and silent-failure modes.
- `/sealed-secrets` — Sealing, rotating, and troubleshooting SealedSecrets.
- (plus workspace copies of the user-global skills listed above)

Sandbox integrity is no longer a workspace command: run `claude-sandbox verify` (outside Claude) for the live battery.
