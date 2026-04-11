# Memo

Save a snapshot of current work to persistent memory, then graduate
reusable knowledge into the repo where others (human and AI) can find it.

## Step 1 — Save current state

Write a concise summary of in-progress or recently completed work to
the project's `MEMORY.md` file. Include:

- What was done and current status (completed, blocked, in-progress)
- Key decisions or outcomes

Do not duplicate information already in skills, CLAUDE.md, or repo docs.

## Step 2 — Promote reusable knowledge

Review the memory file for items that go beyond session-specific state.
Graduate each item to the **most appropriate permanent home**:

### → Repo docs (for humans and AI)
Reference knowledge that helps anyone working with the project:
- Troubleshooting patterns (symptoms, causes, fixes)
- Service-specific gotchas and operational notes
- How-to steps for non-obvious procedures

Place these in the existing doc structure (e.g. `docs/reference/troubleshooting.md`,
`docs/how-to/`, relevant README files).

### → CLAUDE.md (for AI specifically)
Foot-guns and rules that prevent silent failures:
- Commands that silently do nothing (wrong tag names, wrong file patterns)
- Naming conventions where violations cause cryptic errors
- Hard constraints the AI must always follow

Keep CLAUDE.md concise — only add items where AI is likely to make mistakes.

### → Skills (for AI procedural knowledge)
Multi-step procedures the AI should follow when invoked:
- Workflows with specific ordering requirements
- Checklists for complex operations
- Decision trees for choosing between approaches

### → Remove from memory
Once an item is promoted, remove it from memory. It now lives somewhere
better.

## Step 3 — Trim memory

Remove from memory anything that is:
- Already captured in skills, CLAUDE.md, or repo docs
- Too specific to a single task to be useful in future sessions
- Stale or superseded by later work

Keep memory concise — ideally under 30 lines of genuinely transient state.
