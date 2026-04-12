# Lessons learned using Claude Code for infrastructure

This page analyses the architectural choices and working practices that allow
an LLM agent (Claude Code) to operate this K3s cluster project with minimal
human supervision — including autonomous multi-hour rebuilds. The goal is to
extract transferable techniques for other infrastructure projects.

## What makes this project complex

This is not a toy cluster. The complexity comes from several dimensions
stacking on top of each other:

| Dimension | Detail |
|-----------|--------|
| **Hardware** | Heterogeneous: 4× RK1 ARM SoCs on a Turing Pi board, plus x86 nodes (NUC, workstation) with different roles and taints |
| **Services** | 20 ArgoCD-managed applications — cert-manager, ingress-nginx, Grafana, Prometheus, Supabase, Open Brain, and more |
| **Provisioning layers** | Ansible (OS + K3s) → Helm (ArgoCD root app) → ArgoCD (everything else) — three layers, each with its own failure modes |
| **Stateful data** | Postgres databases, Grafana dashboards, Prometheus metrics, chat history — all must survive cluster rebuilds |
| **Secret management** | Vault-derived secrets, SealedSecrets, OAuth client credentials, cookie secrets — each with different rotation rules |
| **Auth stack** | GitHub OAuth → oauth2-proxy → Dex → per-service OIDC — a four-hop chain where any link can break silently |

An agent that can operate this system safely is doing something non-trivial.
The rest of this page explains what makes it possible.

## The enablement pattern

### Guardrails before capabilities

The project's `CLAUDE.md` file (68 lines) establishes hard boundaries before
granting any capabilities. The most important rules:

- **Never mutate the live cluster** — no `kubectl apply/patch/delete` on
  ArgoCD-managed resources. All fixes go through the CD pipeline.
- **Never commit to main** — work in branches, merge when verified.
- **Local PV data paths are sacred** — the decommission playbook preserves
  `/home/k8s-data` and `/var/lib/k8s-data` by default.

These are not suggestions. They are structural constraints that make entire
categories of mistakes impossible. The devcontainer reinforces this
structurally: host SSH agent forwarding is explicitly disabled
(`SSH_AUTH_SOCK: ""`), preventing prompt-injection attacks from accessing
host SSH keys. Git credential helpers are set to `none`. Credentials are
scoped per-repository via named Docker volumes.

### Encoded operational knowledge

The `.claude/` directory contains **1,506 lines** across 14 files — more
configuration surface than many of the services it manages:

| Type | Count | Total lines | Purpose |
|------|-------|-------------|---------|
| Commands | 6 | 1,106 | Step-by-step runbooks (rebuild, bootstrap, add-node, test-oauth, pr-squash, memo) |
| Skills | 4 | 355 | On-demand domain knowledge (ansible, sealed-secrets, oauth, cloudflare) |
| Settings | 2 | 45 | Permission model and hooks |

The largest single file is `rebuild-cluster.md` at 375 lines — an 8-phase
runbook encoding knowledge from real incidents: WaitForFirstConsumer PV
binding, Prometheus webhook bootstrap races, OAuth cookie collisions across
namespaces, and the precise order of Dex restarts after a reseal.

This knowledge would otherwise live in a human operator's head. Encoding it
in machine-readable runbooks means the agent performs rebuilds the same way
every time, without forgetting steps.

### Configuration concentration

The entire cluster's configuration lives in two files totalling **135 lines**:

- `group_vars/all.yml` (59 lines) — cluster-level variables: node names,
  IP addresses, domain, storage paths
- `kubernetes-services/values.yaml` (76 lines) — service toggles and
  version pins

Four boolean flags control which optional services are deployed. When Claude
needs to enable or disable a service, there is exactly one place to look.
This concentration is deliberate: a small change surface means fewer places
for an agent to make mistakes, and fewer files to read before understanding
the system state.

### Self-healing architecture

GitOps via ArgoCD provides a critical safety net: the cluster continuously
reconciles toward the desired state declared in git. If Claude makes a
mistake in a manifest, the fix is another commit — not manual kubectl
surgery. If a deployment drifts, ArgoCD corrects it automatically.

Ansible is similarly idempotent. Running the playbook twice produces the
same result. This means Claude can re-run provisioning without fear of
compounding errors.

The combination creates a system where mistakes are recoverable by default.
Push a fix, wait for sync. The blast radius of any single error is bounded
by the git diff.

### Incremental workflow

Every change follows the same cycle:

1. **Branch** — never commit to main
2. **Plan** — use plan mode to align on approach before writing code
3. **Implement** — make changes, run lint, build docs
4. **Test** — for rebuild-affecting changes, run `/rebuild-cluster` on the
   branch
5. **Squash** — use `/pr-squash` to clean up history into targeted commits
6. **Merge** — merge the PR, preserving the curated commit structure

This workflow gives the human operator a review gate at every stage. The
agent proposes; the human approves. Trust is built incrementally, not
granted wholesale.

## Working practices: the human side

The repo structure enables Claude, but operational habits determine whether
the collaboration is effective. These practices are not evident from the
code alone.

### Context hygiene

- Start each major change with a clean context (`/clear`)
- Use plan mode first to align on approach, then exit and execute
- The **plan-clean-execute cycle**: plan in one context, `/clear`, execute
  in fresh context with the plan file as the guide — avoids stale
  assumptions accumulating
- Always [`/memo`](https://github.com/gilesknap/tpi-k3s-ansible/blob/main/.claude/commands/memo.md) before `/clear`. This custom
  command reviews the current conversation and automatically promotes what
  was learned into the right permanent home: foot-guns and constraints go
  to CLAUDE.md, procedural knowledge goes to skills, troubleshooting
  patterns go to repo docs, and transient state goes to memory. It then
  trims anything that has been promoted. The effect is a knowledge ratchet:
  nothing useful evaporates between sessions, and the system gets smarter
  with every `/clear`.

### Keep long-running command output out of context

Long-running commands like `ansible-playbook` can produce thousands of
lines of output. When this streams directly into the conversation context,
it crowds out important earlier decisions and makes it harder for the agent
to reason about what happened. The fix is a two-tool pattern:

- **`run_in_background`** executes the command and captures all output to a
  log file — nothing enters the conversation until a completion notification.
- A parallel **`Monitor`** tails the log through a tight filter
  (e.g. `grep --line-buffered -E '^(PLAY \[|fatal:|PLAY RECAP)'` for
  Ansible), surfacing only progress markers and failures in real time.

The result: the conversation reads as a clean narrative of phase
transitions and errors, while the full log is available via targeted file
reads when needed. This is a context-clarity technique, not just a
token-saving one — cleaner context means better reasoning and fewer lost
decisions during multi-hour operations.

### Incremental trust building

- Start with small, reversible changes; graduate to autonomous rebuilds
- Each successful PR expands the boundary of what Claude is trusted to do
- Feedback loops: corrections become feedback memories and CLAUDE.md rules,
  preventing the same mistake twice. Running `/memo` at the end of a
  session encodes these corrections automatically, so the next session
  starts with the lessons already in place

### Collaborate first, then execute from the plan

Avoid jumping straight to imperative instructions like "change X to Y" —
these put the LLM on rails and bypass its ability to reason about
alternatives. Instead, discuss the problem in plan mode, reach consensus
on the approach, and let the resulting plan file bound the scope naturally.
Execution requests then reference the agreed plan rather than prescribing
steps, and Claude has the context to make good judgement calls along the
way.

### Adversarial planning

Use plan mode as a genuine two-way review gate, not a rubber stamp. The
human challenges scope creep and wrong assumptions; Claude challenges
feasibility and suggests alternatives. The Longhorn migration started not
as "drop Longhorn" but as a planning session where the operator asked how
to achieve data retention across rebuilds and proposed several options —
Claude evaluated trade-offs and the decision to use local PVs emerged from
the discussion. Catching a bad assumption in planning costs one exchange;
catching it mid-implementation costs unwinding work.

### Document complexity as you encounter it

When a task reveals non-obvious behaviour — a bootstrap race condition, a
secret derivation quirk, a Helm values interaction — document it in the
repo docs immediately, not later. This serves both humans and future Claude
contexts: the next session that touches that area gets the explanation
loaded automatically rather than having to rediscover it from scratch.

### Curate `.claude/` as a first-class project artifact

Treat the `.claude/` directory — commands, skills, settings, CLAUDE.md —
as production code, not throwaway config. Periodically review it: are
skills still accurate after an architecture change? Do commands reflect
current procedures? Has a hard rule become obsolete? `/memo` keeps things
up to date incrementally, but conscious review catches drift that
incremental updates miss.

### Skills as institutional memory

Skills encode earned knowledge from real incidents — the sealed-secrets
skill traces to three distinct production traps. `/memo` updates them
automatically, so each session's lessons are available to the next.

### Structural safety over behavioural safety

The devcontainer's SSH agent isolation and credential scoping mean Claude
literally cannot perform certain dangerous actions even if its reasoning
goes wrong. This is more reliable than rules that say "don't do X" — the
capability is removed, not just discouraged. Invest in making bad actions
impossible rather than just forbidden.

## Techniques for other projects

These are concrete, actionable steps drawn from the patterns above.

1. **Write CLAUDE.md rules for your invariants.** Every project has things
   that must never happen. Write them down as hard rules, not guidelines.
   "Never run migrations in production" is a rule. "Be careful with
   migrations" is a wish.

2. **Concentrate configuration.** The fewer files an agent needs to read to
   understand system state, the fewer mistakes it will make. Two files
   totalling 135 lines is better than 20 files totalling 2,000 lines, even
   if the latter is more "modular."

3. **Use GitOps or equivalent reconciliation.** If mistakes are fixed by
   pushing a commit rather than running manual commands, the blast radius is
   bounded and recovery is mechanical. An agent operating on a system
   without reconciliation can cause damage that requires expert manual
   intervention.

4. **Encode operational knowledge as runbooks.** Complex multi-step
   procedures (rebuilds, migrations, incident response) should be
   machine-readable command files, not wiki pages. A 375-line runbook that
   an agent follows precisely is more reliable than a human following a
   checklist from memory.

5. **Isolate credentials structurally.** Don't rely on rules saying "don't
   use the host SSH key." Disable the host SSH agent in the container
   configuration. Don't rely on "don't commit secrets." Use pre-commit
   hooks that block them. Structural isolation survives reasoning failures.

6. **Build trust incrementally.** Start with read-only tasks, graduate to
   reversible changes, then to supervised destructive operations. Each
   successful iteration earns more autonomy. Don't grant full access on
   day one.

7. **Make CLAUDE.md a living document.** Update rules when the system
   changes. The Longhorn-to-local-PV migration added two new rules in the
   same PR as the cutover. Stale rules are worse than no rules — they
   teach the agent to ignore constraints.

8. **Use plan mode as a genuine gate.** Require plan-mode review for
   non-trivial changes. Challenge assumptions, push back on scope creep,
   and verify that the agent understands the constraints before it starts
   writing code.

9. **Invest in devcontainer toolchain pinning.** A reproducible environment
   means the agent's local behaviour matches what will happen in CI and
   production. Version-pinned tools, cached dependencies, and pre-installed
   hooks eliminate an entire class of "works on my machine" failures.

10. **Graduate learnings into durable storage.** When something goes wrong,
    don't just fix it — encode the fix as a skill, CLAUDE.md rule, or
    memory. The `/memo` command automates this. The cost of encoding is
    minutes; the cost of re-discovering the same issue is hours. This is
    the knowledge ratchet: each session leaves the system smarter than it
    found it.

11. **Reuse project-agnostic commands.** Two commands in this repo's
    `.claude/commands/` directory — `/memo` and `/pr-squash` — are not
    specific to K3s or Ansible. Copy them into your own project to get the
    same workflow benefits without writing them from scratch.

12. **Keep long-running output out of context.** Commands like
    `ansible-playbook` or `helm install` can produce thousands of lines.
    Run them in the background with output captured to a file, and attach
    a Monitor with a tight filter that surfaces only progress markers and
    errors. The agent sees a clean narrative instead of a wall of noise,
    and can read the full log on demand when something fails. This is a
    clarity technique — the agent reasons better when its context contains
    decisions and outcomes rather than raw command output.
