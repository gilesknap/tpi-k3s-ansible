# AGENTS.md — Guidance for AI Coding Agents

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

1. **Flash breaks after NVME migration** — `ubuntu-rockchip-install` changes the boot device away from eMMC; subsequent flashes to eMMC won't take effect.
2. **`known_hosts` must be `serial: 1`** — parallel writes to `~/.ssh/known_hosts` cause race conditions.
3. **Traefik is disabled** — K3s ships Traefik by default, but this project passes `--disable=traefik` and uses NGINX Ingress instead.
4. **Working in branches** — you must pass `-e repo_branch=<branch>` so ArgoCD syncs the correct branch.
5. **No automated tests** — changes should be validated by running the relevant playbook tags against a test cluster.

---

## File Editing Guidance
