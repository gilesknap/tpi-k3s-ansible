---
description: Rescan BOTH ~/.claude and the current workspace .claude and refresh the hardcoded list inside /toolbox.
---

Refresh the hardcoded listing inside `~/.claude/commands/toolbox.md` (and the workspace `./.claude/commands/toolbox.md` if present) so it matches the current state of disk. claude-sandbox's adapted `toolbox` enumerates BOTH locations — Claude actually loads from both, so the listing must reflect both.

## Steps

1. Enumerate user-global commands: every `*.md` file in `~/.claude/commands/`. The command name is the filename minus `.md`.

2. Enumerate user-global skills: every `SKILL.md` under `~/.claude/skills/**/`. Take `name` from frontmatter.

3. Enumerate workspace commands: every `*.md` file in `./.claude/commands/` (relative to the current working directory).

4. Enumerate workspace skills: every `SKILL.md` under `./.claude/skills/**/`.

5. For each file, extract the frontmatter `description` field. Trim to the first sentence (stop at the first `.` followed by space or end of string). If a description spans multiple sentences with extra detail, keep only the first.

6. Build the new listing block in this exact format, sorted alphabetically within each section:

   ```
   **User-global commands (`~/.claude/commands/`)**
   - `/<name>` — <description>
   ...

   **User-global skills (`~/.claude/skills/`)**
   - `/<name>` — <description>
   ...

   **Workspace commands (`./.claude/commands/`)**
   - `/<name>` — <description>
   ...

   **Workspace skills (`./.claude/skills/`)**
   - `/<name>` — <description>
   ...
   ```

   Show skill names with a leading `/` so they render with the same highlighting as commands, even though skills aren't slash-invocable. If a section is empty, write `- (none)`.

7. Edit `~/.claude/commands/toolbox.md`. Replace everything **after** the line `Output exactly the following text verbatim, with no preamble, commentary, or trailing summary:` (and the blank line that follows) with the freshly-built listing. Preserve the frontmatter and the instruction line above it. If `./.claude/commands/toolbox.md` exists, do the same to it.

8. Print a single line confirmation: `Updated toolbox.md — <N_user_commands>+<N_workspace_commands> commands, <M_user_skills>+<M_workspace_skills> skills.`
