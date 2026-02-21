# AGENTS.md — Guidance for AI Coding Agents

## Terminal Tool Usage

When using the `run_in_terminal` tool:

- The tool result may show only a minimal acknowledgment (e.g., `#` with a timestamp) rather than the actual command output
- **ALWAYS** use `terminal_last_command` tool afterward to retrieve the actual output if the `run_in_terminal` result appears empty or truncated
- Check the exit code in the context to determine if the command succeeded before assuming failure

**CRITICAL: Avoid repeating commands**

- The `<context>` block at the start of each user message contains terminal state including:
  - `Last Command`: The command that was run
  - `Exit Code`: Whether it succeeded (0) or failed
- **BEFORE** running a command, check if the context already shows it ran successfully
- **NEVER** re-run a command that the context shows already completed with exit code 0
- If you need the output and the context doesn't show it, use `terminal_last_command` once - do not re-run the command

**Common mistake to avoid:**
- ❌ Run command → Get minimal output → Try to run same command again
- ✅ Run command → Get minimal output → Check context for exit code → Use `terminal_last_command` to get full output
- The `run_in_terminal` tool often returns minimal acknowledgment, but the command still executed successfully
- Always check the context in the next turn - if Exit Code: 0, the command succeeded; just get the output with `terminal_last_command`

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
- BMC hostname: `turingpi`, user: `root`
- node02, node03, node04 have NVMEs and previously had `move_fs` run
- node01 (CM4) is currently being flashed after BMC power-cycle fixed USB errors
- Branch in use: `add-cloudflared` (ArgoCD must be passed `-e repo_branch=add-cloudflared`)

### Key Findings This Session
- **All `tpi flash` USB errors were caused by a BMC USB enumeration bug** — fixed by power-cycling the BMC. NOT caused by NVME migration.
- `ubuntu-rockchip-install` does NOT change the boot device — eMMC remains the bootloader. Re-flashing eMMC always fully restores a node.
- `move_fs` role is correct as-is; the old comment claiming it broke flashing was wrong (now fixed).

### What Was Fixed This Session
- `ansible.cfg`: `stdout_callback = ansible.builtin.default` + `result_format = yaml` (community.general.yaml removed in v12)
- `roles/tools/tasks/helm.yml`: helm-diff health check uses `failed_when: false` (not `ignore_errors`) to suppress red output; reinstalls if broken
- `roles/known_hosts/tasks/main.yml`: `ssh-keyscan` is non-fatal; skips offline/unresolvable nodes
- `roles/move_fs/tasks/move_fs.yml`: `ansible_mounts` → `ansible_facts['mounts']`; corrected misleading comment
- `group_vars/all.yml`: `do_flash` checks `flash_force` first; `ansible_default_ipv4` → `ansible_facts['default_ipv4']`; `control_plane_ip` removed (set as fact in k3s role instead)
- `roles/flash/tasks/node.yml`: `flash_force | bool` added to `when:` conditions
- `roles/k3s/tasks/main.yml`: `control_plane_ip` set as `set_fact` here (hostvars available at task time)
- `roles/flash/tasks/bootstrap.yml`: `wait_for` (port 22, delegated to localhost) after MSD switch; `until:` added to block device retry
- `roles/flash/tasks/flash.yml`: removed `> /tmp/flash.log` redirect; added power-cycle + 10s pause before flash; `failed_when` catches `Error occured` in stdout; retries 3x with power-cycle between attempts
- `roles/flash/vars/main.yml`: RPi4 image updated to `24.04.4` with correct SHA
- `roles/move_fs/tasks/move_fs.yml`: comment corrected — `ubuntu-rockchip-install` keeps eMMC as boot device

### Next Steps
1. **Confirm node01 flash completes successfully**
2. **Run full playbook** for all nodes: `ansible-playbook pb_all.yml -e flash_force=true -e repo_branch=add-cloudflared`
3. **If flash USB errors recur** on other nodes: power-cycle the BMC (not the nodes)
4. **Verify cluster comes up**: K3s control plane on node01, workers on node02/03/04
5. **Verify ArgoCD deploys** kubernetes-services from `add-cloudflared` branch
6. **Primary goal of this branch**: add cloudflared tunnel service to the cluster

### Files Created This Session (may be cleaned up)
- `pb_recover_nvme.yml` — no longer needed (NVME migration doesn't break flashing); can be deleted
- `roles/flash/tasks/recover_nvme_boot.yml` — no longer needed; can be deleted
- `docs/recover-rk1-maskrom.md` — no longer needed; can be deleted