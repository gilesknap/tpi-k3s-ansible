---
description: Save current task state to auto-memory, then promote reusable lessons to skills and trim memory.
---

# Memo

Save a snapshot of current work to persistent memory, then clean up.

## Step 1 — Save current state

Write a concise summary of in-progress or recently completed work to the
auto-memory `MEMORY.md` for this project. Include:

- What was done (feature, bug, refactor, area of code)
- Current status (completed, blocked, in-progress)
- Key decisions or outcomes worth remembering across conversations

Do not duplicate information already in skills, CLAUDE.md, or README-CLAUDE.md.

## Step 2 — Promote to skills

Review the memory file for items that represent **reusable patterns or
lessons** — things that would help future sessions on this project. For
each such item:

1. Identify which skill file it belongs in (or create a new one under
   `.claude/skills/<name>/SKILL.md`).
2. Add it to the appropriate skill.
3. Remove it from memory (it now lives in the skill).

Examples of promotable items:
- A non-obvious convention specific to this project
- A "foot-gun" pattern worth warning future-you about
- A reusable recipe (test invocation, deploy command, debugging trick)

## Step 3 — Trim memory

Remove from memory anything that is:
- Already captured in skills, CLAUDE.md, or README-CLAUDE.md
- Too specific to a single completed task to be useful again
- Stale or superseded by later work

Keep memory concise — ideally under 30 lines.
