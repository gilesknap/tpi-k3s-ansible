# Lessons learned using Claude Code for infrastructure

This page sets out the choices in this repo, and the working habits around
it, that let an LLM agent (Claude Code) operate the gkcluster.org cluster
with little supervision, up to rebuilding it unattended. It is the part of
these docs most likely to be useful to someone else: the cluster is
specific to one home, but the techniques carry over to other
infrastructure projects.

For how Claude is fenced in (the sandbox, its network jail and its
credentials), see {doc}`/explanations/architecture/claude-code`. For the
set-up steps, see {doc}`/how-to/claude-code`.

## What makes this project complex

This is not a toy cluster. The complexity comes from several dimensions
stacking on top of each other:

| Dimension | Detail |
|-----------|--------|
| **Hardware** | Mixed: three RK1 arm64 modules on a Turing Pi board (node02, node03, node04), two amd64 NUCs (nuc1, nuc2) and a GPU workstation (ws03), each with its own role, taints and devices ({doc}`/explanations/architecture/hardware`) |
| **Services** | 27 ArgoCD applications (a root and 26 children): the platform (Cilium, ingress-nginx, cert-manager, cloudflared, Sealed Secrets, oauth2-proxy), monitoring, and the things the cluster is for (scrap, Jellyfin, the Minecraft dashboard, ntfy) |
| **Provisioning layers** | Ansible (OS and K3s), then Ansible installing ArgoCD and its root application, then ArgoCD for everything else, with OpenTofu for the Cloudflare edge alongside. Each layer fails in its own way |
| **Stateful data** | Grafana and Prometheus on node04; Jellyfin's library database on nuc2; scrap's database, replicated to the NAS; every Minecraft world on the NAS. All of it must survive a rebuild ({doc}`/explanations/architecture/storage`) |
| **Secret management** | 13 SealedSecrets, sealed again on every rebuild because the sealing key is new. Some values are generated at random, some come from outside (GitHub OAuth apps, Cloudflare, Tailscale, Google Drive), and some are held by clients and must not change (scrap's MCP token, the ntfy tokens) |
| **Auth stack** | Cloudflare Access at the edge, then ingress-nginx, then either Dex (ArgoCD, Grafana, argocd-monitor) or oauth2-proxy (Headlamp, Alertmanager, scrap, Minecraft), all ending at GitHub. A chain where any link can break without an error ({doc}`/explanations/architecture/authentication`) |

An agent that can operate this system safely is doing something non-trivial.
The rest of this page explains what makes it possible.

## The enablement pattern

### Guardrails before capabilities

The project's `CLAUDE.md` file (about 115 lines) establishes hard boundaries before
granting any capabilities. The most important rules:

- **Never mutate the live cluster** — no `kubectl apply/patch/delete` on
  ArgoCD-managed resources. All fixes go through the CD pipeline.
- **Never commit to main** — work in branches, merge when verified.
- **Local PV data paths are sacred** — the decommission playbook preserves
  `/home/k8s-data` and `/var/lib/k8s-data` by default, and nothing but the
  `k8s_data_dirs` role may write under `/var/lib/k8s-data` on an RK1.
- **Never write to the first 16 MiB of an RK1's eMMC**, where U-Boot lives.

Each rule names its exceptions (`kubeseal`, `ansible-playbook --tags
cluster`, restarting a workload), so the agent does not have to guess
where the edge is.

Rules in a file are still only rules. The devcontainer backs them with a
boundary that does not depend on the agent's behaviour: Claude runs in a
sandbox that cannot see the owner's SSH agent or keys, can reach only the
listed cluster addresses, and pushes with a token scoped to this repo
({doc}`/explanations/architecture/claude-code`).

### Encoded operational knowledge

The `.claude/` directory contains **about 2,000 lines** across 10 files, more
than many of the services it manages:

| Type | Count | Total lines | Purpose |
|------|-------|-------------|---------|
| Commands | 5 | about 1,300 | Step-by-step runbooks (rebuild, bootstrap, add-node, test-oauth, pr-squash) |
| Skills | 5 | about 700 | On-demand domain knowledge (ansible, argocd, sealed-secrets, oauth, cloudflare) |

The largest single file is `rebuild-cluster.md` at about 580 lines — an 8-phase
runbook encoding knowledge from real incidents: WaitForFirstConsumer PV
binding, Prometheus webhook bootstrap races, OAuth cookie collisions across
namespaces, the precise order of Dex restarts after a reseal, and a gate
that refuses to start until every Minecraft world is somewhere a rebuild
will find it again.

This knowledge would otherwise live in a human operator's head. Encoding it
in machine-readable runbooks means the agent performs rebuilds the same way
every time, without forgetting steps.

### Configuration concentration

Almost every cluster-level choice lives in two files totalling **about 590
lines**, most of it comments:

- `group_vars/all.yml` (about 165 lines) — the control plane and its
  standby, the API name, cluster domain, admin emails, repo URL, the host
  directories behind the local volumes
- `kubernetes-services/values.yaml` (about 425 lines) — service switches,
  version pins, NAS paths and the maintenance windows

A third file, `hosts.yml` (under 70 lines), owns the hardware: the node
names and the per-node flags (`workstation`, `nvidia_gpu_node`,
`intel_gpu_node`, `node_ip`). It is a small, single place to look when the
agent needs to know which machine does what. The Cloudflare edge follows
the same idea: one list, `tunnel_services` in `cloudflare/locals.tf`, is
every public hostname.

The comments are part of the design. Where two files must agree, each
says so at the point of use with a `SYNC:` note (for example the
`local_storage` entries in `values.yaml` and the `k8s_data_dirs` entries in
`all.yml`), so an agent editing one is told about the other.

Six `enable_*` flags in `values.yaml` control the optional services and
features (`enable_oauth2_proxy`, `enable_cloudflare_tunnel`,
`enable_minecraft`, `enable_vps_relay`, `enable_jellyfin` and
`enable_kyverno`, the last of which is off). When Claude
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

### Guard rails written as code

Where a rule can be checked by a machine, it is, so that it does not rest
on anyone remembering it:

- **The edge refuses to publish an unprotected hostname.**
  `cloudflare/access_guard.tf` holds preconditions that fail `tofu plan`
  if a public hostname has no Cloudflare Access application in front of
  it, or if an application that lets anyone in targets a hostname not
  marked `access_bypass = true` in `locals.tf`. Adding a service to the
  list cannot expose it by accident, whoever makes the change.
- **Checks have no off switch.** `just check` runs `ansible-lint` and the
  Sphinx build with warnings as errors, and `CLAUDE.md` forbids `# noqa`
  and `warn_list` entries, so the agent's only way past a warning is to
  fix it.
- **Secrets cannot be committed by mistake.** gitleaks runs in pre-commit
  and in CI, and lets a SealedSecret through only if its file is named
  `*-secret.yaml`.
- **New releases wait two weeks.** The comments beside the image and
  chart pins in `values.yaml` (rclone, age, Jellyfin, sqlite) record that
  each was pinned to a release at least two weeks old when chosen, as a
  buffer against a compromised release, and tell whoever bumps them to
  keep the rule. The one exception is written down with its date and
  reason next to the pin it applies to.
- **Downloads are checked.** Binaries fetched at run time (age in the
  off-site backup, the Headlamp Argo CD plugin) are pinned by sha256 in
  `values.yaml`, and the pod will not start on a mismatch.

### Incremental workflow

Every change follows the same cycle:

1. **Branch** — never commit to main
2. **Plan** — use plan mode to align on approach before writing code
3. **Implement** — make changes, run lint, build docs
4. **Test** — for rebuild-affecting changes, run `/rebuild-cluster` on the
   branch
5. **Merge** — merge the PR with a merge commit, keeping its commits
   (`/pr-squash` first, only if the history is exploratory)

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
- Always `/memo` before `/clear`. This custom command (a user-level skill,
  not part of this repo) reviews the current conversation and automatically promotes what
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
the discussion (recorded in
{doc}`ADR 12 </explanations/decisions/0012-drop-longhorn>`). Catching a bad assumption in planning costs one exchange;
catching it mid-implementation costs unwinding work.

### Verify a subagent's "it isn't there"

Long tasks are split across subagents, and a subagent's report is only as
good as its search. `CLAUDE.md` carries a rule for this: a **negative**
finding ("X is never written", "tag Z does not exist") must be checked with
a grep before any guidance is deleted or rewritten because of it. A
positive finding that quotes a file is cheap to trust; a negative one
requires the search to have been exhaustive, and indirect call chains
(justfile, then script, then playbook, then role) are easy to miss. Acting
on a false negative removes documentation or a skill that something still
depends on.

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

The sandbox's isolation from the owner's SSH agent, its network jail and
the repo-scoped GitHub token mean Claude cannot perform certain dangerous
actions even if its reasoning goes wrong. This is more reliable than rules
that say "don't do X": the capability is removed, not just discouraged.
The same thinking gives Claude a key of its own for the nodes
(`just claude-ssh-bootstrap`), which can be revoked with one command
without touching the owner's. Invest in making bad actions impossible
rather than just forbidden.

## Techniques for other projects

These are concrete, actionable steps drawn from the patterns above.

1. **Write CLAUDE.md rules for your invariants.** Every project has things
   that must never happen. Write them down as hard rules, not guidelines.
   "Never run migrations in production" is a rule. "Be careful with
   migrations" is a wish.

2. **Concentrate configuration.** The fewer files an agent needs to read to
   understand system state, the fewer mistakes it will make. Two config
   files plus an inventory file totalling a few hundred lines is better than 20
   files totalling 2,000 lines, even if the latter is more "modular."

3. **Use GitOps or equivalent reconciliation.** If mistakes are fixed by
   pushing a commit rather than running manual commands, the blast radius is
   bounded and recovery is mechanical. An agent operating on a system
   without reconciliation can cause damage that requires expert manual
   intervention.

4. **Encode operational knowledge as runbooks.** Complex multi-step
   procedures (rebuilds, migrations, incident response) should be
   machine-readable command files, not wiki pages. A 580-line runbook that
   an agent follows precisely is more reliable than a human following a
   checklist from memory.

5. **Isolate credentials structurally.** Don't rely on rules saying "don't
   use the host SSH key." Run the agent where it cannot see the key or the
   agent socket. Don't rely on "don't commit secrets." Use pre-commit
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

11. **Reuse project-agnostic commands.** One command in this repo's
    `.claude/commands/` directory, `/pr-squash`, is not specific to K3s or
    Ansible: copy it into your own project to get the same workflow
    benefits without writing it from scratch. `/memo` is a user-level skill
    that is not in this repository; the idea (save state, promote lessons
    to skills) is easy to recreate.

12. **Keep long-running output out of context.** Commands like
    `ansible-playbook` or `helm install` can produce thousands of lines.
    Run them in the background with output captured to a file, and attach
    a Monitor with a tight filter that surfaces only progress markers and
    errors. The agent sees a clean narrative instead of a wall of noise,
    and can read the full log on demand when something fails. This is a
    clarity technique — the agent reasons better when its context contains
    decisions and outcomes rather than raw command output.

13. **Turn rules into failing checks.** A rule the agent must remember
    will one day be forgotten; a precondition that fails the plan will
    not. `cloudflare/access_guard.tf` is the model here: the policy
    "nothing public without a login" is a few lines of code that stop the
    change before it reaches Cloudflare.

14. **Make the agent verify absence.** Require a direct search before
    acting on any "not found" from a subagent or a summary. Wrongly
    deleting something load-bearing costs far more than one grep.

15. **Write the reason next to the value.** A pin with a comment saying
    why it is pinned, what else must change with it and what rule governs
    bumping it is something an agent can maintain. A bare version number
    is something it will "tidy".
