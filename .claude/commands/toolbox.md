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
- `/verify-sandbox` — Run the 17-check sandbox PASS/FAIL battery against the live process.

**Workspace skills (`./.claude/skills/`)**
- (none unless installed via `claude-sandbox install-skill`)
