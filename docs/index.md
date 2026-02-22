# K3s Cluster Commissioning

An Infrastructure-as-Code project that commissions a production-ready
[K3s](https://k3s.io/) Kubernetes cluster using [Ansible](https://www.ansible.com/),
with continuous deployment via [ArgoCD](https://argo-cd.readthedocs.io/).

Supported hardware:

- **Turing Pi v2.5** boards with RK1 or CM4 compute modules
- **Any Linux server** with Ubuntu 24.04 LTS (Intel NUC, Raspberry Pi, VMs, cloud instances)
- **Mixed clusters** combining Turing Pi nodes with standalone servers

## Key Features

- Automated flashing of Turing Pi compute modules with Ubuntu 24.04 LTS
- Optional OS migration to NVMe storage
- Multi-node K3s cluster with a single control plane
- GitOps-driven service deployment via ArgoCD
- Let's Encrypt TLS certificates via DNS-01 validation
- Optional Cloudflare tunnel for secure public access
- Fully idempotent — safe to re-run at any time
- Devcontainer-based execution environment (podman + VS Code)

## Documentation

::::{grid} 1 2 2 2
:gutter: 3

:::{grid-item-card} {octicon}`mortar-board` Tutorials
:link: tutorials
:link-type: doc

Step-by-step guides to get your cluster running from scratch.
:::

:::{grid-item-card} {octicon}`tools` How-To Guides
:link: how-to
:link-type: doc

Task-oriented recipes for common operations and configuration.
:::

:::{grid-item-card} {octicon}`light-bulb` Explanations
:link: explanations
:link-type: doc

Background knowledge: architecture, design decisions, and how things work.
:::

:::{grid-item-card} {octicon}`book` Reference
:link: reference
:link-type: doc

Technical reference: variables, tags, services, inventory format.
:::

::::

```{toctree}
:maxdepth: 1
:hidden:

tutorials
how-to
explanations
reference
```
