# Architecture

This page describes the overall architecture of the K3s Cluster Commissioning project —
how the pieces fit together from hardware to running services.

## System overview

```mermaid
flowchart TB
    subgraph Workstation["Developer Workstation"]
        DC[DevContainer<br/>Ansible + kubectl + helm]
    end

    subgraph TuringPi["Turing Pi v2.5"]
        BMC[BMC<br/>SSH + tpi CLI]
        N1[node01<br/>Control Plane]
        N2[node02<br/>Worker]
        N3[node03<br/>Worker]
        N4[node04<br/>Worker]
    end

    subgraph Extra["Extra Nodes"]
        E1[nuc1<br/>Worker]
        E2[nuc2<br/>Worker]
    end

    subgraph Cluster["K3s Cluster"]
        K3S[K3s Control Plane]
        ARGO[ArgoCD]
        SVC[Services<br/>cert-manager, ingress-nginx,<br/>Longhorn, Grafana, etc.]
    end

    subgraph Git["Git Repository"]
        REPO["kubernetes-services/<br/>templates/ + additions/"]
    end

    DC -->|"1. Flash (via BMC)"| BMC
    BMC -->|"tpi flash"| N1 & N2 & N3 & N4
    DC -->|"2. Install K3s"| K3S
    DC -->|"3. Deploy ArgoCD"| ARGO
    ARGO -->|"4. Sync services"| SVC
    REPO -->|"GitOps"| ARGO
    DC -->|"SSH"| E1 & E2
```

## Layers

### Hardware layer

The project supports two types of compute nodes:

- **Turing Pi nodes** — compute modules (RK1, CM4) installed in a Turing Pi v2.5 board.
  The BMC provides remote management (flashing, power control) via SSH and the `tpi` CLI.
- **Extra nodes** — any standalone Linux server (Intel NUC, Raspberry Pi, VM, etc.)
  with Ubuntu 24.04 and SSH access.

Both types join the same K3s cluster as either the control plane or workers.

### Provisioning layer (Ansible)

Ansible orchestrates the entire setup through a sequence of roles:

```mermaid
flowchart LR
    T[tools] --> F[flash] --> KH[known_hosts] --> S[servers] --> K[k3s] --> C[cluster]
```

| Role | Purpose | Runs on |
|------|---------|---------|
| `tools` | Install helm, kubectl, kubeseal in devcontainer | localhost |
| `flash` | Flash Ubuntu to Turing Pi compute modules via BMC | BMC hosts |
| `known_hosts` | Update SSH known_hosts (serial: 1) | All hosts |
| `move_fs` | Migrate OS from eMMC to NVMe | Nodes with `root_dev` |
| `update_packages` | dist-upgrade, install dependencies | All nodes |
| `k3s` | Install K3s control plane and workers | All nodes |
| `cluster` | Deploy ArgoCD, bootstrap services | localhost |

Each role is idempotent — it checks state before acting and does nothing if the desired
state is already achieved.

### Kubernetes layer (K3s)

[K3s](https://k3s.io/) is a lightweight, CNCF-certified Kubernetes distribution. This
project uses it because:

- **Lightweight** — single binary, low resource footprint, ideal for ARM SBCs
- **Batteries included** — built-in CoreDNS, metrics-server, local-path provisioner
- **Simple** — easy to install, upgrade, and uninstall

Notable configuration:

- **Traefik is disabled** — K3s ships Traefik by default, but this project uses
  NGINX Ingress instead (`--disable=traefik`)
- **Control plane is tainted** (multi-node only) — `NoSchedule` taint prevents
  workloads from running on the control plane node; skipped for single-node clusters
- **etcd mode** — single control plane with `--cluster-init` (embedded etcd)

### GitOps layer (ArgoCD)

After Ansible installs ArgoCD, all further service management is done via Git:

```mermaid
flowchart LR
    DEV[Developer] -->|"git push"| GIT[Git Repo]
    GIT -->|"poll/webhook"| ARGO[ArgoCD]
    ARGO -->|"sync"| K8S[Kubernetes]
    K8S -->|"self-heal"| K8S
```

ArgoCD continuously reconciles the cluster state with the repository. See
{doc}`gitops-flow` for a detailed explanation.

## Why these choices?

| Choice | Rationale |
|--------|-----------|
| K3s over K8s | Lightweight, single binary, ideal for ARM and small clusters |
| ArgoCD over Flux | Mature, excellent UI, widely adopted |
| NGINX Ingress over Traefik | More widely documented, better TLS passthrough support |
| Longhorn over Rook-Ceph | Simpler, lower resource overhead, good for small clusters |
| cert-manager + DNS-01 | Works for LAN-only services that have no public HTTP route |
| Sealed Secrets over SOPS | Kubernetes-native, no external key management needed |
| DevContainer over bare metal | Reproducible execution environment, zero host contamination |
