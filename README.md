[![Documentation](https://img.shields.io/badge/docs-online-blue)](https://gilesknap.github.io/tpi-k3s-ansible/)
[![License](https://img.shields.io/badge/license-Apache%202.0-green)](https://github.com/gilesknap/tpi-k3s-ansible/blob/main/LICENSE)

# K3s Cluster Commissioning

An **Infrastructure-as-Code** Ansible project that commissions a
[K3s](https://k3s.io/) Kubernetes cluster on
[Turing Pi](https://turingpi.com/) v2.5 boards (RK1 / CM4 compute modules)
and arbitrary additional Linux servers — fully idempotent and repeatable.

All cluster customisation lives in just **two files**
(`group_vars/all.yml` and `kubernetes-services/values.yaml`),
so you can fork the repo, edit those files, and have your own cluster running
in minutes.

## Architecture at a glance

The cluster is GitOps-first: Ansible bootstraps K3s and ArgoCD, then
ArgoCD syncs everything else from `kubernetes-services/` in this repo.
Stateful data lives on **static `local-nvme` PVs** — one per workload,
pinned to a specific node — with **daily and weekly CronJob backups to
NFS** on a NAS. This keeps operations simple (no replicated CSI driver)
while still surviving cluster rebuilds and giving off-cluster
point-in-time restore. See the
[**Interactive Architecture Showcase**](https://gilesknap.github.io/tpi-k3s-ansible/_static/architecture.html)
for a visual tour, the [architecture explanation](https://gilesknap.github.io/tpi-k3s-ansible/explanations/architecture.html)
for the layered model, and the
[services reference](https://gilesknap.github.io/tpi-k3s-ansible/reference/services.html)
for quick-start configurations (LLM-only, AI memory, monitoring, full
stack) to help you pick which services to run.

Source          | <https://github.com/gilesknap/tpi-k3s-ansible>
:---:           | :---:
Documentation   | <https://gilesknap.github.io/tpi-k3s-ansible>

## Features

### Infrastructure

- **Automated flashing** of Turing Pi compute modules with Ubuntu 24.04 LTS
- **Optional NVMe migration** — move the root filesystem to fast storage
- **K3s cluster** with one control-plane node and multiple workers
- **Works with any modern Linux server** — Turing Pi hardware is optional
- **Kernel tuning** — DaemonSet for network buffers and multipathd fixes

### GitOps & Deployment

- **GitOps via ArgoCD** — all services deployed and managed declaratively
- **Fork-friendly** — two-file configuration for easy customisation
- **Sealed Secrets** — encrypt secrets safely in Git
- **Reusable ingress sub-chart** — shared template with OAuth, SSL redirect,
  SSL passthrough, and basic-auth toggles

### Networking & Security

- **Ingress + TLS** — NGINX ingress with Let's Encrypt certificates
  (DNS-01 via Cloudflare)
- **OIDC authentication** — ArgoCD Dex with GitHub connector provides native
  OIDC for ArgoCD, Grafana, and Open WebUI; oauth2-proxy covers Headlamp
  and Supabase Studio
- **Cloudflare Tunnel + Access** — optional secure public access via
  cloudflared with email-based access control

### Services

- **Monitoring** — Prometheus + Grafana stack
- **Persistent storage** — static `local-nvme` PVs per host, with daily/weekly NFS backup CronJobs to a NAS
- **Kubernetes dashboard** — Headlamp with RBAC
- **Supabase** — self-hosted backend with PostgreSQL + pgvector, Auth, Storage
  (MinIO-backed), and Studio UI
- **Echo test service** — for verifying ingress, TLS, and headers

### AI / LLM

- **Local LLM inference** — NPU-accelerated RKLLama on RK1 nodes
- **Local LLM inference** — NVIDIA GPU-accelerated llama.cpp on compatible
  servers (with automatic device plugin for GPU scheduling)
- **Open WebUI** — chat interface to the above LLM backends
- **Open Brain** — MCP server providing AI memory and semantic search for
  Claude.ai, backed by Supabase with GitHub OAuth access control

### Developer Experience

- **Devcontainer** — complete execution environment with zero host dependencies
- **Claude Code integration** — AI-assisted workflow with safe autonomy guardrails

## Quick Start

1. Install [Podman](https://podman.io/) and VS Code
2. Fork this repo, clone it, and reopen in the devcontainer
3. Edit `group_vars/all.yml` and `kubernetes-services/values.yaml`
   to match your environment
4. Run:

```bash
ansible-playbook pb_all.yml -e do_flash=true
```

<!-- README only content. Anything below this line won't be included in index.md -->

See <https://gilesknap.github.io/tpi-k3s-ansible> for full documentation.
