# K3s Cluster Commissioning

[![Documentation](https://img.shields.io/badge/docs-online-blue)](https://gilesknap.github.io/tpi-k3s-ansible/)
[![License](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)

An **Infrastructure-as-Code** Ansible project that commissions a K3s Kubernetes
cluster on [Turing Pi](https://turingpi.com/) v2.5 boards (RK1 / CM4 compute
modules) and arbitrary additional Linux servers — fully idempotent and repeatable.

## Features

- **Automated flashing** of Turing Pi compute modules with Ubuntu 24.04 LTS
- **Optional NVME migration** — move the root filesystem to fast storage
- **K3s cluster** with one control-plane node and multiple workers
- **GitOps via ArgoCD** — all services deployed and managed declaratively
- **Ingress + TLS** — NGINX ingress with Let's Encrypt certificates (DNS-01)
- **Monitoring** — Prometheus + Grafana stack
- **Distributed storage** — Longhorn with snapshots and backup
- **Sealed Secrets** — encrypt secrets safely in Git
- **Local LLM inference** — NPU-accelerated LLM server (RKLLama) on RK1 nodes
- **Additional GPU Accelerated LLM** server is coming soon
- **Open WebUI chat** interface to above LLM models
- **Devcontainer** — complete execution environment with zero host dependencies
- Works with **any Linux server** — Turing Pi hardware is optional

## Quick start

1. Install [Podman](https://podman.io/) (or Docker) and VS Code
2. Clone this repo and reopen in the devcontainer
3. Edit `hosts.yml` and `group_vars/all.yml` to match your environment
4. Run:

```bash
ansible-playbook pb_all.yml -e do_flash=true
```

## Documentation

Full documentation is available at
**<https://gilesknap.github.io/tpi-k3s-ansible/>** and covers:

- **Tutorials** — step-by-step setup for Turing Pi and generic Linux servers
- **How-to guides** — bootstrap, services, secrets, Cloudflare, branches, and more
- **Explanations** — architecture, GitOps flow, Ansible roles, networking
- **Reference** — inventory format, variables, tags, services, CLI tools, troubleshooting

## Acknowledgements

- [@procinger](https://github.com/procinger) for ArgoCD patterns —
  [turing-pi-v2-cluster](https://github.com/procinger/turing-pi-v2-cluster)
- [drunkcoding.net](https://drunkcoding.net/posts/ks-00-series-k8s-setup-local-env-pi-cluster/)
  for Kubernetes setup tutorials
- [K3s](https://k3s.io/) — lightweight CNCF-certified Kubernetes
- [Turing Pi](https://turingpi.com/) — compact multi-node compute platform
