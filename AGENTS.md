# AGENTS.md — Guidance for AI Coding Agents

## Project Overview

This is an **Infrastructure-as-Code (IaC)** Ansible project that commissions a **K3s Kubernetes cluster** on Turing Pi v2.5 boards (with RK1 or CM4 compute modules) and arbitrary extra Linux nodes. It flashes Ubuntu 24.04 LTS, installs K3s, and deploys services via ArgoCD — all idempotent and repeatable.

**License:** Apache 2.0  
**Primary Runtime:** Ansible (Python-based), Helm, kubectl  
**Target OS:** Ubuntu 24.04 LTS on cluster nodes; Debian-based devcontainer for the execution environment  

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

## How to Run

All commands run from the repo root directory.

```bash
# Full cluster build (includes flashing)
ansible-playbook pb_all.yml -e do_flash=true

# Rebuild k3s and redeploy services (no flash)
ansible-playbook pb_all.yml --tags k3s,cluster -e k3s_force=true

# Deploy only cluster services
ansible-playbook pb_all.yml --tags cluster

# Add extra (non-Turing Pi) nodes
ansible-playbook pb_add_nodes.yml

# Working in a branch/fork — pass branch and remote to ArgoCD
ansible-playbook pb_all.yml --tags cluster -e repo_branch=my_branch -e repo_remote=https://github.com/user/fork.git
```

---

## Playbook Tags

Tags let you run subsets of the playbook. They correspond to roles:

| Tag | Role(s) | Runs On | Description |
|---|---|---|---|
| `tools` | `tools` | localhost | Install helm, kubectl, convenience scripts |
| `flash` | `flash` | turing_pis (BMCs) | Flash OS images (requires `-e do_flash=true`) |
| `known_hosts` | `known_hosts` | all_nodes, turing_pis | Refresh SSH host keys |
| `servers` | `move_fs`, `update_packages` | all_nodes | Prepare nodes (NVME migration, apt updates) |
| `k3s` | `k3s` | all_nodes | Install/update K3s control plane and workers |
| `cluster` | `cluster` | localhost | Deploy ArgoCD and cluster services |

---

## Key Variables (group_vars/all.yml)

| Variable | Default | Purpose |
|---|---|---|
| `ansible_account` | `ansible` | User created on each node |
| `control_plane` | `node01` | Node designated as K3s control plane |
| `cluster_domain` | `gkcluster.org` | DNS domain for the cluster |
| `domain_email` | (set in file) | Email for Let's Encrypt certificates |
| `repo_remote` | GitHub HTTPS URL | Git repo ArgoCD syncs from |
| `repo_branch` | `main` | Git branch ArgoCD syncs from |
| `admin_password` | `notgood` | **Must override on CLI** (`-e admin_password=...`) |
| `do_flash` | `false` | Enable flashing; pass `-e do_flash=true` |
| `cluster_install_list` | `[argocd]` | Services installed directly (rest managed by ArgoCD) |
| `local_domain` | `.lan` | DNS suffix for local node lookups |
| `bin_dir` | `$BIN_DIR` or `~/bin` | Where tools are installed in the execution environment |

---

## Roles — What They Do

### `tools`
Installs CLI tools (helm, kubectl) and convenience scripts into the devcontainer. Creates shell completions and aliases (`k` → `kubectl`).

### `flash`
Flashes Ubuntu 24.04 onto Turing Pi compute modules via BMC API. Downloads OS images, SCPs to BMC, runs `tpi flash`. Then bootstraps via cloud-init (injects SSH key, hostname, ansible user). Uses the `raw` module since BMC has no Python.

### `known_hosts`
Refreshes SSH known_hosts entries. **Must run with `serial: 1`** — parallel writes cause race conditions.

### `move_fs`
Migrates root filesystem to NVME for nodes with `root_dev` set. Only runs on nodes with that host variable defined.

### `update_packages`
Runs `dist-upgrade`, installs required packages (`open-iscsi` for Longhorn, `unattended-upgrades`), reboots if needed.

### `k3s`
Installs K3s. Control plane uses `--disable=traefik --cluster-init`. Workers get join tokens from control plane. Fetches kubeconfig to localhost. Supports `k3s_force` for reinstall.

### `cluster`
Taints control plane with `NoSchedule`, installs ArgoCD via OCI Helm chart. ArgoCD then manages all other services by syncing the `kubernetes-services/` Helm chart from git.

---

## Kubernetes Services (ArgoCD-managed)

The `kubernetes-services/` directory is a meta Helm chart. Each template in `templates/` defines an ArgoCD `Application` that deploys a service:

| Service | Chart Source | Purpose |
|---|---|---|
| cert-manager | jetstack.io | TLS certificate management + Let's Encrypt |
| dashboard | kubernetes.github.io/dashboard | K8s Dashboard |
| echo | Custom manifest | Test echo server |
| grafana | kube-prometheus-stack | Monitoring (Prometheus + Grafana) |
| ingress | ingress-nginx | NGINX Ingress Controller |
| longhorn | charts.longhorn.io | Distributed storage |
| sealed-secrets | bitnami-labs | Encrypted secrets in git |
| kernel-settings | Inline manifest | Sysctl tuning DaemonSet |
| minecraft | Separate git repo | Game servers |

**Pattern:** Most services use a reusable ingress sub-chart at `additions/ingress/` for standardized NGINX ingress + TLS configuration.

**Additions folder:** Extra manifests applied alongside Helm charts (RBAC, ClusterIssuers, VolumeSnapshotClasses, custom ConfigMaps).

---

## GitOps Flow

1. Ansible installs ArgoCD directly
2. ArgoCD reads `kubernetes-services/` from the configured git repo/branch
3. Each template becomes a child ArgoCD `Application`
4. All apps auto-sync with prune + self-heal enabled
5. **To update services: push changes to git** — ArgoCD picks them up automatically

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
- Global vars in `group_vars/all.yml`. Role-specific vars in `roles/<role>/vars/main.yml`.
- Sensitive values (like `admin_password`) should be overridden on the command line. Ansible Vault infrastructure exists but is not actively used for most secrets.

---

## DevContainer

- **Base image:** `mcr.microsoft.com/devcontainers/python:2-3.14`
- **Pre-installed:** `ansible`, `ansible-lint`, `helm`, `kubectl`, `jmespath`, `kubernetes` Python lib
- **Network:** `--network=host` (required to reach the cluster)
- **Persistent volumes:** `iac2-bin` (tools), `iac2-ssh` (SSH keys), `iac2-kube` (kubeconfig)
- **Container runtime:** Rootless Podman (set VS Code `dev.containers.dockerPath` to `podman`)

---

## Dependency Management

- **Renovate** (`renovate.json`): Automates version bumps for Helm charts, ArgoCD apps, and Go modules. Custom regex managers for K3S System Upgrade Controller CRDs. Auto-merges certain updates.
- **Dependabot** (`.github/dependabot.yml`): Monthly updates for devcontainer features only.
- **No CI/CD pipelines** — no GitHub Actions workflows exist. Testing is manual.

---

## Important Warnings & Gotchas

1. **Flash breaks after NVME migration** — `ubuntu-rockchip-install` changes the boot device away from eMMC; subsequent flashes to eMMC won't take effect.
2. **`known_hosts` must be `serial: 1`** — parallel writes to `~/.ssh/known_hosts` cause race conditions.
3. **Traefik is disabled** — K3s ships Traefik by default, but this project passes `--disable=traefik` and uses NGINX Ingress instead.
4. **`admin_password` defaults to `notgood`** — always override on the command line. It's used in Grafana Helm values as well.
5. **Working in branches** — you must pass `-e repo_branch=<branch>` so ArgoCD syncs the correct branch.
6. **IP stability** — nodes use DHCP; fixed DHCP reservations are recommended to avoid IP changes on reboot.
7. **Auto port-forwarding disabled** — the devcontainer disables VS Code auto port-forwarding due to looping issues. Use the convenience scripts (`grafana.sh`, `argo.sh`, etc.) instead.
8. **`TROBLESHOOT.md`** — note the filename typo (missing 'U'). Contains notes about RK1 USB device detection issues during flashing.
9. **`old-cluster-tasks/`** — deprecated; kept for reference. All services are now managed through ArgoCD via `kubernetes-services/`.
10. **No automated tests** — changes should be validated by running the relevant playbook tags against a test cluster.

---

## File Editing Guidance

When modifying this project:

- **Adding a new cluster service:** Create a template in `kubernetes-services/templates/<service>.yaml` as an ArgoCD `Application`. Add any extra manifests in `kubernetes-services/additions/<service>/`. The service will be auto-deployed by ArgoCD on the next git sync.
- **Adding a new role:** Create `roles/<role>/tasks/main.yml` (and optionally `vars/main.yml`). Add the role to `pb_all.yml` in the appropriate play. Add a descriptive tag.
- **Changing node inventory:** Edit `hosts.yml`. For new Turing Pi boards, add both a BMC entry under `turing_pis` and a node group named `<bmc_hostname>_nodes`.
- **Updating Helm chart versions:** Edit the version in the relevant `kubernetes-services/templates/*.yaml` file. Renovate may also create PRs for this automatically.
- **Modifying global config:** Edit `group_vars/all.yml`. Remember that `control_plane`, `cluster_domain`, and `repo_remote` are critical — changing them affects the entire cluster.
