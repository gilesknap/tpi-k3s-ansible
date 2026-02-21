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

## Project Overview

This is an **Infrastructure-as-Code (IaC)** Ansible project that commissions a **K3s Kubernetes cluster** on Turing Pi v2.5 boards (with RK1 or CM4 compute modules) and arbitrary extra Linux nodes. It flashes Ubuntu 24.04 LTS, installs K3s, and deploys services via ArgoCD — all idempotent and repeatable.

**License:** Apache 2.0
**Primary Runtime:** Ansible (Python-based), Helm, kubectl
**Target OS:** Ubuntu 24.04 LTS on cluster nodes; Debian-based devcontainer for the execution environment

See `README.md` for setup instructions, how to run playbooks, and available tags.

---

## Repository Structure

```
├── pb_all.yml                  # Main playbook — runs all roles in sequence
├── pb_add_nodes.yml            # Standalone: add non-Turing Pi nodes to Ansible control
├── hosts.yml                   # Inventory: BMCs, Turing Pi nodes, extra nodes
├── group_vars/all.yml          # Global variables (personalization, cluster config)
├── ansible.cfg                 # Ansible configuration (inventory path, stdout format)
├── roles/
│   ├── tools/                  # Install CLI tools (helm, kubectl, scripts) in devcontainer
│   ├── flash/                  # Flash Ubuntu onto Turing Pi compute modules via BMC
│   ├── known_hosts/            # Update SSH known_hosts (must run serial: 1)
│   ├── move_fs/                # Move root filesystem to NVME
│   ├── update_packages/        # Dist-upgrade, install dependencies (open-iscsi, etc.)
│   ├── k3s/                    # Install K3s control plane + workers
│   └── cluster/                # Deploy cluster services (ArgoCD, then ArgoCD manages the rest)
├── kubernetes-services/        # Meta Helm chart deployed by ArgoCD (all cluster services)
│   ├── Chart.yaml
│   ├── templates/              # ArgoCD Application manifests for each service
│   └── additions/              # Extra K8s manifests per service (RBAC, issuers, etc.)
├── argo-cd/                    # Jinja2 templates for ArgoCD bootstrap (applied by Ansible)
├── .devcontainer/              # DevContainer config (Dockerfile, devcontainer.json)
├── pub_keys/                   # SSH public keys for node access
├── docs/                       # Documentation (setup, cloudflare, notes)
└── old-cluster-tasks/          # Deprecated: pre-ArgoCD direct Ansible installs
```

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
- Sensitive values (like `admin_password`) should be overridden on the command line.

---

## Important Warnings

1. **`tpi flash` USB errors** — if `tpi flash` fails with `Error occured during flashing: "USB"`, power-cycle the BMC (not just the nodes). This is a BMC firmware USB enumeration bug. `ubuntu-rockchip-install` does NOT change the boot device — eMMC remains the bootloader — so re-flashing eMMC always restores the node fully.
2. **`known_hosts` must be `serial: 1`** — parallel writes to `~/.ssh/known_hosts` cause race conditions.
3. **Traefik is disabled** — K3s ships Traefik by default, but this project passes `--disable=traefik` and uses NGINX Ingress instead.
4. **Working in branches** — you must pass `-e repo_branch=<branch>` so ArgoCD syncs the correct branch.
5. **No automated tests** — changes should be validated by running the relevant playbook tags against a test cluster.

---

## File Editing Guidance
---

## Current Session State (as of 2026-02-21)

### Hardware
- Turing Pi v2.5, 4 slots: node01=CM4 (slot 1), node02/03/04=RK1 (slots 2-4)
- BMC hostname: `turingpi` → `192.168.1.80`
- node01 (control plane) → `192.168.1.81`, workers on .82/.83/.84
- DNS entries for all cluster services (`*.gkcluster.org`) point to `192.168.1.81`
- Branch in use: `llm-simplify`

### Cluster Status
- Cluster is **up and running** — K3s, ArgoCD, ingress-nginx, cert-manager, longhorn, grafana, echo all deployed
- ArgoCD UI accessible via: `kubectl port-forward svc/argocd-server -n argo-cd 8080:443` → https://localhost:8080
- ArgoCD also accessible at https://argocd.gkcluster.org once DNS resolves
- Initial admin password: `kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
- `kubernetes-dashboard` (Headlamp) and `rkllama` not yet fully synced as of end of session

### What Was Fixed This Session
- `roles/tools/tasks/helm.yml`:
  - Helm upgraded **3.16.4 → 3.20.0** — required to support `platformHooks` field in helm-diff 3.x plugin.yaml (older helm refused to load the plugin)
  - Broken helm-diff plugin now removed via `ansible.builtin.file state=absent` (not `helm plugin uninstall` which also fails when plugin is broken)
  - `ansible_env.HOME` → `set_fact: user_home` pattern (consistent with k3s role, avoids deprecation warning)
- `kubernetes-services/values.yaml` **created** — contains `repo_branch: llm-simplify`
  - ArgoCD checks this out at the same `targetRevision` as the root app, so `repo_branch` is always self-referential
  - Child apps inherit the correct branch automatically when root app `targetRevision` is changed
- `argo-cd/argo-git-repository.yaml` — removed `repo_branch` from `valuesObject` (now comes from `values.yaml` instead)
- `docs/bootstrap.md` **created** — documents how to bootstrap the cluster and access ArgoCD/Headlamp

### Known Deprecation Warnings (not fixable in user code)
These come from `kubernetes.core` collection 6.3.0 — upstream bug, harmless:
- `Importing 'to_bytes/to_native/to_text' from 'ansible.module_utils._text' is deprecated`
- `Passing 'warnings' to exit_json or fail_json is deprecated`

### Important: Branch Propagation for Child Apps
- The root `all-cluster-services` app passes `repo_branch` to child apps via Helm values
- `repo_branch` now lives in `kubernetes-services/values.yaml` (checked out at root app's `targetRevision`)
- **When changing root app target branch**: the live `all-cluster-services` Application CR may have an old `repo_branch` in its `valuesObject` that overrides `values.yaml`. Remove it:
  ```bash
  kubectl patch application all-cluster-services -n argo-cd --type json \
    -p '[{"op":"remove","path":"/spec/source/helm/valuesObject/repo_branch"}]'
  ```
- Each branch must have the correct `repo_branch` value in its own `kubernetes-services/values.yaml`

### Next Steps
1. **Debug remaining OutOfSync/Unknown ArgoCD apps** one at a time: `kubernetes-dashboard`, `rkllama`, `grafana-prometheus`
2. **Verify Headlamp** deploys and is accessible at https://headlamp.gkcluster.org
3. **Verify rkllama** deploys correctly (primary goal of this branch)
4. Token for Headlamp: `kubectl create token headlamp -n headlamp --duration=24h`