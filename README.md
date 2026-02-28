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

Source          | <https://github.com/gilesknap/tpi-k3s-ansible>
:---:           | :---:
Documentation   | <https://gilesknap.github.io/tpi-k3s-ansible>

## Features

### Infrastructure

- **Automated flashing** of Turing Pi compute modules with Ubuntu 24.04 LTS
- **Optional NVMe migration** — move the root filesystem to fast storage
- **K3s cluster** with one control-plane node and multiple workers
- **Works with any Linux server** — Turing Pi hardware is optional
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
- **OAuth2 authentication** — GitHub OAuth gateway (oauth2-proxy) protecting
  Grafana, Longhorn, Headlamp, and Open WebUI
- **Cloudflare Tunnel** — optional secure public access via cloudflared

### Services

- **Monitoring** — Prometheus + Grafana stack
- **Distributed storage** — Longhorn with snapshots and backup
- **Kubernetes dashboard** — Headlamp with RBAC
- **Local LLM inference** — NPU-accelerated RKLLama on RK1 nodes
- **Local LLM inference** — NVIDIA GPU-accelerated llama.cpp on compatible servers
- **Open WebUI** — chat interface to the above LLM backends
- **Echo test service** — for verifying ingress, TLS, and headers

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
