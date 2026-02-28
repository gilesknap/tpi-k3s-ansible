# Using Claude Code

This project includes [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
configuration for AI-assisted development with safe autonomy guardrails.

## Configuration

`.claude/settings.json` defines three permission tiers:

**Allow** — runs without confirmation:
: Read-only operations (`git status`, `kubectl get`, `helm list`, etc.),
  file editing, `uv run`, `gh` CLI, `ansible-lint`

**Prompt** — asks for confirmation each time:
: Infrastructure mutations (`ansible-playbook`, `kubectl apply/patch/delete`,
  `git push --force`, `git reset --hard`)

**Deny** — blocked entirely:
: Nothing is denied by default. Move commands here if you want to hard-block them.

## AGENTS.md

The `AGENTS.md` file at the repo root provides project-specific guidance to AI
agents. It covers:

- GitOps workflow (fix in the repo, not the cluster)
- Ansible conventions (update roles, not ad-hoc commands)
- Project structure and service directory layout
- Ingress sub-chart toggles
- OAuth2 architecture
- Dual `repo_branch` synchronisation
- Inventory conventions and playbook tags

## Workflow

1. Open the repo in the devcontainer (tools are installed automatically)
2. Launch Claude Code from the VS Code extension or CLI
3. The agent reads `AGENTS.md` and `.claude/settings.json` on startup
4. Safe read-only commands run automatically; infrastructure changes prompt
   for approval

## Customising permissions

Edit `.claude/settings.json` to adjust. Move entries between `allow`, `prompt`,
and `deny` lists as needed. Patterns use glob syntax — `Bash(kubectl get *)`
matches any `kubectl get` command.
