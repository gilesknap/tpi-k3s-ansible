# AGENTS.md — Guidance for AI Coding Agents

## Terminal Tool Usage

When using the `run_in_terminal` tool:

- The shell prompt is **two lines**, e.g.:
  ```
  root@ws03: /workspaces/tpi-k3s-llm llm-simplify
  #
  ```
- `run_in_terminal` returns the command output **followed by** this two-line prompt as a terminator
- When you see only the two prompt lines with nothing before them, the command produced no output (e.g. a silent `git add`) — this is normal and does not indicate failure
- Read whatever appears **before** the prompt lines as the actual command output
- Check the exit code in the `<context>` block to confirm success/failure — do not assume failure just because output looks minimal
- **DO NOT use `terminal_last_command`** to try to retrieve output — it reads from the user's currently focused VS Code terminal, which is a completely different terminal from where `run_in_terminal` executes, so it will return unrelated output

**CRITICAL: Avoid repeating commands**

- The `<context>` block at the start of each user message contains terminal state including:
  - `Last Command`: The command that was run
  - `Exit Code`: Whether it succeeded (0) or failed
- **BEFORE** running a command, check if the context already shows it ran successfully
- **NEVER** re-run a command that the context shows already completed with exit code 0

**When you need to capture output for later reading** (e.g. long output, or output needed across turns):

Redirect to a temp file and read it back:
```
run_in_terminal: some-command > /tmp/out.txt 2>&1
read_file: /tmp/out.txt
```

---

## GitOps: Always Fix in the Repo, Never in the Cluster

**CRITICAL: Do not patch, edit, or apply resources directly to the cluster to fix problems.**

ArgoCD manages all cluster state — any direct `kubectl apply`, `kubectl patch`, or `kubectl edit`
will either be immediately reverted by ArgoCD's self-heal, or will create drift that obscures the
true state of the system.

The correct workflow for any fix is always:
1. Edit the relevant file(s) in the repo
2. `git commit` and `git push`
3. ArgoCD detects the change and reconciles the cluster automatically

The only legitimate `kubectl` commands during a fix are **read-only** (e.g. `kubectl get`,
`kubectl logs`, `kubectl describe`) to diagnose the problem before editing the repo.

The one exception is generating and committing **SealedSecrets** — `kubeseal` reads from the
live cluster's public key, but the resulting file is committed to the repo and applied by ArgoCD,
so it still follows the GitOps flow.

---

## Ansible: Always Update Roles, Never Run Ad-hoc Commands

**CRITICAL: Do not suggest or run ad-hoc `ansible` or `ansible-playbook` commands to fix or
configure nodes.**

All node configuration is managed by Ansible roles in `roles/`. Any required package, setting,
or file that needs to be present on cluster nodes must be encoded in the appropriate role so it
is applied idempotently on every future node provisioning.

The correct workflow for any node-level change is always:
1. Edit the relevant role task file (e.g. `roles/update_packages/tasks/main.yml`)
2. `git commit` and `git push`
3. The user re-runs the relevant playbook/tag against their cluster

Common roles to update:
- **`roles/update_packages`** — OS packages that must be present on all nodes
- **`roles/tools`** — CLI tools (helm, kubectl, kubeseal, etc.) installed on the control node
- **`roles/k3s`** — K3s installation and configuration
- **`roles/cluster`** — ArgoCD bootstrap and cluster-level setup

---

## Cloudflare Tunnel UI Notes

The Cloudflare Zero Trust dashboard public hostname configuration has **no separate "Service
Type" field**. The protocol is specified as a prefix in the Service URL itself:

- Use `http://hostname:port` for plain HTTP to the backend
- Use `https://hostname:port` for HTTPS to the backend

Example: `http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local:80`

---

## Project Overview

This is an **Infrastructure-as-Code (IaC)** Ansible project that commissions a **K3s Kubernetes cluster** on Turing Pi v2.5 boards (with RK1 or CM4 compute modules) and arbitrary extra Linux nodes. It flashes Ubuntu 24.04 LTS, installs K3s, and deploys services via ArgoCD — all idempotent and repeatable.

**License:** Apache 2.0
**Primary Runtime:** Ansible (Python-based), Helm, kubectl
**Target OS:** Ubuntu 24.04 LTS on cluster nodes; Debian-based devcontainer for the execution environment

Full documentation lives in `docs/` (Sphinx + MyST). Build with `uv run tox -e docs`.
See `README.md` for a quick-start summary.

---

## GitOps Flow

1. Ansible installs ArgoCD directly (via the `cluster` role)
2. ArgoCD reads `kubernetes-services/` from the configured git repo/branch
3. Each template in `kubernetes-services/templates/` becomes a child ArgoCD `Application`
4. All apps auto-sync with prune + self-heal enabled
5. **To update services: push changes to git** — ArgoCD picks them up automatically

Most services use a reusable ingress sub-chart at `additions/ingress/` for standardized NGINX ingress + TLS. Extra manifests (RBAC, ClusterIssuers, etc.) go in `additions/<service>/`.

---

## Inventory Conventions

- **Node group naming:** Turing Pi node groups **must** be named `<bmc_hostname>_nodes` (e.g., `turingpi_nodes` for BMC host `turingpi`). The flash role discovers nodes using this convention.
- **Per-node variables:** `slot_num` (BMC slot 1-4), `type` (`rk1` or `pi4`), `root_dev` (optional: target block device for NVME migration).
- **Groups:** `all_nodes` is the union of all Turing Pi node groups + `extra_nodes`.

---

## Coding Conventions

### Ansible Tasks
- **Idempotency:** Every task uses `creates:`, `when:` guards, stat checks, or registration to be safe for re-runs.
- **Force flags:** `do_flash`/`flash_force`, `k3s_force`, `cluster_force` — all default `false`, override via `-e`.
- **Delegation:** BMC tasks use the `raw` module (no Python on BMC). Many tasks delegate to `localhost` or `{{ control_plane }}`.
- **Linting:** `ansible-lint` is installed in the devcontainer. Suppress known exceptions with `# noqa <rule-name>` (e.g., `no-changed-when`, `no-handler`, `command-instead-of-shell`).
- **YAML style:** 2-space indentation. Task names are sentence-case descriptions.

### Kubernetes Manifests
- Templates in `kubernetes-services/templates/` are ArgoCD `Application` CRDs using Helm values.
- Additions in `kubernetes-services/additions/` are plain YAML or Helm values applied alongside the main charts.
- Ingress resources follow a consistent pattern via the reusable `additions/ingress/` sub-chart.

### Variables
- Global vars in `group_vars/all.yml` (well-commented — read it directly). Role-specific vars in `roles/<role>/vars/main.yml`.
- Sensitive values use `admin-auth` Kubernetes secrets created during bootstrap.

---

## Important Warnings

1. **`tpi flash` USB errors** — if `tpi flash` fails with `Error occured during flashing: "USB"`, power-cycle the BMC (not just the nodes). This is a BMC firmware USB enumeration bug. `ubuntu-rockchip-install` does NOT change the boot device — eMMC remains the bootloader — so re-flashing eMMC always restores the node fully.
2. **`known_hosts` must be `serial: 1`** — parallel writes to `~/.ssh/known_hosts` cause race conditions.
3. **Traefik is disabled** — K3s ships Traefik by default, but this project passes `--disable=traefik` and uses NGINX Ingress instead.
4. **Working in branches** — `repo_branch` in `kubernetes-services/values.yaml` controls which branch ArgoCD child apps track. Each branch must set this value to match itself. See "Branch Propagation" below.
5. **No automated tests** — changes should be validated by running the relevant playbook tags against a test cluster.

---

## Dual repo_branch Variables — Always Update Both

There are **two separate `repo_branch` variables** that must always be kept in sync:

1. **`group_vars/all.yml`** — used by Ansible at bootstrap time to create the root ArgoCD Application CR
2. **`kubernetes-services/values.yaml`** — used by ArgoCD's Helm engine at runtime to set `targetRevision` on all child apps

They cannot be unified because they are consumed by completely different systems at different stages.
**Whenever switching branches, update `repo_branch` in both files.**

---

## Branch Propagation for ArgoCD Child Apps

The root `all-cluster-services` ArgoCD Application passes `repo_branch` to child apps via Helm values. This value lives in `kubernetes-services/values.yaml`, which ArgoCD checks out at the same `targetRevision` as the root app — so it is always self-referential.

**Rules:**
- Each branch must set `repo_branch` in its own `kubernetes-services/values.yaml` to match the branch name.
- The Ansible bootstrap also reads `repo_branch` from `group_vars/all.yml` when creating the root Application CR.

**When switching the root app to a different branch:** the live `all-cluster-services` Application CR may retain an old `repo_branch` in its `valuesObject` that overrides `values.yaml`. Remove it:
```bash
kubectl patch application all-cluster-services -n argo-cd --type json \
  -p '[{"op":"remove","path":"/spec/source/helm/valuesObject/repo_branch"}]'
```

---

## Hardware Reference

- Turing Pi v2.5, 4 slots: node01=CM4 (slot 1), node02/03/04=RK1 (slots 2-4)
- BMC hostname: `turingpi` → `192.168.1.80`
- node01 (control plane) → `192.168.1.81`, workers on `.82`/`.83`/`.84`
- DNS entries for `*.gkcluster.org` point to worker nodes (`.82`/`.83`/`.84` — ingress LoadBalancer IPs), **not** the control plane
