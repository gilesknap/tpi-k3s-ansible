# Services Reference

All services deployed by ArgoCD, with their chart sources, versions, and access
methods. If you are trying to decide *what to install*, start with
**Quick-start configurations** below. If you already know what you want, skip
down to the **Service catalogue** for the reference table and per-service
details.

## Quick-start configurations

Not every cluster needs every service. This section helps you pick a
configuration based on what you actually want to run. Services can be
individually enabled or disabled — see {doc}`/how-to/add-remove-services`.

### Baseline (always installed)

All configurations below assume the baseline plumbing that makes ingress,
TLS, and human login work:

- **cert-manager** — Let's Encrypt TLS via Cloudflare DNS-01
- **ingress-nginx** — HTTP(S) ingress controller
- **oauth2-proxy** — GitHub OAuth gate for services without native OIDC
- **Sealed Secrets** — encrypted secrets committed to Git
- **cloudflared** — outbound Cloudflare tunnel (external access without opening ports)

**Baseline prerequisites:**

- A Cloudflare-managed domain (set via `cluster_domain` in `group_vars/all.yml`)
- A Cloudflare API token with DNS edit + Tunnel permissions
- **Two** GitHub OAuth Apps for human logins — one for Dex (OIDC services)
  and one for oauth2-proxy (services without native OIDC)

See {doc}`/how-to/oauth-setup` and {doc}`/how-to/cloudflare-tunnel` for the
setup steps.

### LLM-only — private ChatGPT

Run local LLMs behind a ChatGPT-style web UI. No databases, no memory,
no external APIs. This is the smallest useful deployment on a pure
Turing Pi cluster.

**Install:** RKLLama (*or* llama.cpp), Open WebUI.

**Hardware prerequisites:**

- **RKLLama** — one or more Rockchip RK1 nodes with NPUs (Turing Pi RK1 modules)
- **llama.cpp** — one x86 node with an NVIDIA GPU (`nvidia_gpu_node: true` in `extra_nodes`)
- **Open WebUI** — one x86 node (pinned to `node04` by default)

Either backend works on its own — or run both and Open WebUI will merge
them in a single model dropdown.

**Storage prerequisites:**

- An NFS share for model files (shared across LLM backends — see {doc}`/how-to/nas-setup`)
- `/var/lib/k8s-data/open-webui` on the Open WebUI host (5Gi for chat history and user accounts)

### AI memory — Claude with long-term recall

Give Claude.ai and Claude Code a persistent memory via an MCP server, backed
by Supabase (PostgreSQL + S3-compatible MinIO). Add Open WebUI if you also
want a browser chat interface over the same backend.

**Install:** Supabase (full stack), Open Brain MCP, *(optionally)* Open WebUI.

**Hardware prerequisites:**

- One x86/amd64 node for the full Supabase stack — 10 pods, all scheduled
  on `amd64` (pinned to `nuc2` by default)
- Optionally: an x86 node for Open WebUI (pinned to `node04`)

**Storage prerequisites:**

- `/home/k8s-data/supabase-db`, `/home/k8s-data/supabase-storage`, and
  `/home/k8s-data/supabase-minio` on the Supabase host
- An NFS share for PostgreSQL backups — see {doc}`/how-to/nas-setup` and
  {doc}`/how-to/backup-restore`

**Other prerequisites:**

- A **third** GitHub OAuth App — Open Brain MCP uses its own OAuth client,
  separate from the baseline Dex and oauth2-proxy apps (see {doc}`/how-to/open-brain`)

### Monitoring-only — dashboards and alerts

Metrics, dashboards, and Slack/email alerting for the cluster and any
workloads you add. Useful as a standalone observability cluster.

**Install:** kube-prometheus-stack (Grafana + Prometheus + Alertmanager).

**Hardware prerequisites:**

- Two x86 nodes — one for Prometheus (pinned to `node02`), one for Grafana
  (pinned to `node03`)

**Storage prerequisites:**

- `/var/lib/k8s-data/prometheus` on the Prometheus host (40Gi)
- `/var/lib/k8s-data/grafana` on the Grafana host (30Gi)

**Other prerequisites:**

- Optional: a Slack webhook for Alertmanager notifications
  (see {doc}`/how-to/monitoring`)

### Full stack — everything

Install every service in the catalogue below. Use this if you have the
hardware and want the full experience out of the box.

**Minimum hardware:**

- 1× x86 node for Supabase (`nuc2` role — hosts the 10-pod Supabase stack)
- 2× x86 nodes for Prometheus and Grafana pinning (`node02`, `node03`)
- 1× x86 node for Open WebUI (`node04`)
- 1× RK1 *or* NVIDIA GPU node for LLM inference (at least one)
- A NAS with two NFS exports: one for LLM model files, one for database backups

**Other prerequisites:**

- Everything listed under the baseline and the individual configurations above

## Service catalogue

| Service | Chart / Source | Version | Namespace | Ingress URL | Auth | Purpose |
|---------|---------------|---------|-----------|-------------|------|---------|
| cert-manager | `jetstack/cert-manager` | v1.20.1 | `cert-manager` | — | — | TLS certificate management |
| cloudflared | Plain manifests | 2026.3.0 | `cloudflared` | — | — | Cloudflare tunnel connector |
| echo | Plain manifests | 0.9.2 | `echo` | `echo.<domain>` | None | HTTP echo test service |
| Grafana + Prometheus | `prometheus-community/kube-prometheus-stack` | 83.0.2 | `monitoring` | `grafana.<domain>` | Dex (OIDC) | Monitoring and dashboards |
| Headlamp | `headlamp/headlamp` | 0.41.0 | `headlamp` | `headlamp.<domain>` | OAuth + Token | Kubernetes dashboard |
| ingress-nginx | `ingress-nginx/ingress-nginx` | 4.15.1 | `ingress-nginx` | — | — | Ingress controller |
| kernel-settings | Inline DaemonSet | — | `kube-system` | — | — | Sysctl tuning for performance |
| oauth2-proxy | `oauth2-proxy/oauth2-proxy` | 10.4.2 | `oauth2-proxy` | `oauth2.<domain>` | GitHub | OAuth proxy for Headlamp and Supabase Studio |
| RKLlama | Helm chart (local) | 0.0.4 | `rkllama` | `rkllama.<domain>` | None | NPU-accelerated LLM server (Rockchip RK1) |
| llama.cpp | Helm chart (local) | — | `llamacpp` | `llamacpp.<domain>` | — | CUDA-accelerated LLM server (NVIDIA GPU) |
| NVIDIA device plugin | `nvidia/nvidia-device-plugin` | 0.19.0 | `nvidia-device-plugin` | — | — | Advertises `nvidia.com/gpu` resources to the scheduler |
| Open WebUI | `open-webui/open-webui` | 13.0.1 | `open-webui` | `open-webui.<domain>` | Dex (OIDC) | ChatGPT-style UI backed by RKLLama and/or llama.cpp |
| Open Brain MCP | Helm chart (local) | — | `open-brain-mcp` | `brain.<domain>` | OAuth 2.1 (GitHub) | Standalone MCP server for AI memory |
| Sealed Secrets | `bitnami-labs/sealed-secrets` | 2.18.4 | `kube-system` | — | — | Encrypted secrets in Git |
| Supabase | `supabase-community/supabase-kubernetes` | — | `supabase` | `supabase.<domain>`, `supabase-api.<domain>` | oauth2-proxy (Studio) + dashboard password, x-brain-key (API) | Self-hosted backend-as-a-service platform |

## Service details

### cert-manager

Manages TLS certificates via Let's Encrypt. Uses DNS-01 validation through the
Cloudflare API. Includes a `ClusterIssuer` (`letsencrypt-prod`) and a SealedSecret
for the Cloudflare API token. Resource limits: 50m/128Mi request, 200m/256Mi limit.

**Additional manifests:** `additions/cert-manager/templates/`
- `cloudflare-api-token-secret.yaml` — SealedSecret for DNS API token
- `issuer-letsencrypt-prod.yaml` — ClusterIssuer for production Let's Encrypt (uses `domain_email` for ACME notifications)

### cloudflared

Outbound Cloudflare tunnel connector. Runs 2 replicas for availability. Reads the
tunnel token from a SealedSecret. Non-root, read-only rootfs. Image pinned to
`2026.3.0`.

**Additional manifests:** `additions/cloudflared/`
- `deployment.yaml` — 2-replica Deployment with hardened security context
- `tunnel-secret.yaml` — SealedSecret for tunnel token

### echo

Simple HTTP echo service ([ealen/echo-server](https://github.com/Ealenn/Echo-Server))
for testing ingress, TLS, and headers. Exposed publicly via Cloudflare tunnel with
`ssl-redirect: false`. Runs as non-root (65534) with read-only root filesystem.
Image pinned to `0.9.2`.

**Additional manifests:** `additions/echo/`
- `manifests.yaml` — Deployment, Service, and Ingress

### Grafana + Prometheus (kube-prometheus-stack)

Full monitoring stack: Prometheus for metrics collection, Grafana for dashboards,
Alertmanager for alerts. Grafana authenticates via Dex (OIDC) with GitHub —
emails in `admin_emails` get Admin role, those in `viewer_emails` get Viewer. Uses
static `local-nvme` PVs pinned by node affinity (Grafana → node03 30Gi,
Prometheus → node02 40Gi). Grafana resource limits: 100m/256Mi request,
500m/512Mi limit.

Uses `ServerSideApply=true` sync option due to large CRDs.

### Headlamp

Modern Kubernetes dashboard. Protected by the cluster-wide oauth2-proxy
(admin-only, same as Supabase Studio). After OAuth login,
paste a ServiceAccount token generated with
`kubectl create token headlamp -n headlamp` to access the Kubernetes API.
The Helm chart creates a ClusterRoleBinding granting `cluster-admin` to
the default ServiceAccount. Resource limits: 50m/128Mi request,
200m/256Mi limit.

### ingress-nginx

NGINX ingress controller. Admission webhooks are disabled. Resource limits:
100m/256Mi request, 500m/512Mi limit. PodDisruptionBudget: minAvailable 1.

### kernel-settings

DaemonSet that applies system tuning on all nodes:
- Sets `rmem_max` and `wmem_max` to 7500000 (network buffers)

All busybox images pinned to `1.37`.

### oauth2-proxy

Lightweight OAuth authentication proxy. Redirects unauthenticated users to GitHub
for login. Protects services without native OIDC support: Headlamp and
Supabase Studio. Integrated with nginx ingress annotations. Resource limits:
10m/64Mi request, 100m/128Mi limit.

**Additional manifests:** `additions/oauth2-proxy/`
- `oauth2-proxy-secret.yaml` — SealedSecret for GitHub OAuth credentials

See {doc}`/how-to/oauth-setup` for configuration details.

### RKLlama

NPU-accelerated LLM inference server for Rockchip RK1 nodes. Runs as a DaemonSet on
nodes labelled `node-type: rk1`. Requires privileged access to `/dev/rknpu`. Models
are stored on an NFS PersistentVolume so they are shared across all RK1 nodes and
persist outside the cluster. Image pinned to `0.0.4`. Startup probe allows up to 5
minutes for model loading.

**Helm chart:** `additions/rkllama/` (local chart, no external registry)
- `templates/configmap.yaml` — CPU/NPU governor tuning script and nginx reverse-proxy config
- `templates/daemonset.yaml` — Main workload (init + rkllama + nginx sidecar containers)
- `templates/ingress.yaml` — Ingress for `rkllama.<domain>`
- `templates/service.yaml` — ClusterIP Service round-robining across DaemonSet pods
- `templates/pv.yaml` — NFS PersistentVolume (server/path from `values.yaml`)
- `templates/pvc.yaml` — PersistentVolumeClaim bound to the NFS PV

**NFS configuration** — edit `kubernetes-services/values.yaml` (the single source of truth):

```yaml
rkllama:
  nfs:
    server: 192.168.1.3   # your NAS IP
    path: /bigdisk/LMModels  # your NFS export path
```

ArgoCD injects these values directly into the rkllama Helm chart. No other file needs
changing (see [Variables Reference](variables.md)).

### llama.cpp (CUDA)

OpenAI-compatible LLM inference server using
[llama.cpp](https://github.com/ggml-org/llama.cpp) with CUDA acceleration. Runs as
a single-replica Deployment scheduled exclusively on nodes labelled
`nvidia.com/gpu.present=true`. Requires an NVIDIA GPU node in `extra_nodes` with
`nvidia_gpu_node: true` in the inventory. Image pinned to `server-cuda-b8172`.
Startup probe allows up to 10 minutes for model loading.

Security context drops all capabilities while retaining GPU access.

Models are stored as GGUF files on an NFS PersistentVolume (a separate subdirectory
from RKLLama — the two formats are incompatible). Exposes an OpenAI-compatible
`/v1` API on port 8080, consumed by Open WebUI.

**NFS and model configuration** — edit `kubernetes-services/values.yaml`:

```yaml
llamacpp:
  nfs:
    server: 192.168.1.3          # your NFS server IP
    path: /bigdisk/LMModels/cuda # separate from rkllama — GGUF files only
  model:
    file: "mistral-7b-instruct-v0.2.Q4_K_M.gguf"
    gpuLayers: 99        # offload all layers to GPU
    contextSize: 8192
    parallel: 4
    memoryLimit: "24Gi"
```

See {doc}`/how-to/llamacpp-models` for how to download models to the NFS share.

### NVIDIA device plugin

DaemonSet that detects NVIDIA GPUs and advertises `nvidia.com/gpu` resources to the
Kubernetes scheduler. Schedules on nodes with label `nvidia.com/gpu.present=true`
(applied by the `k3s` Ansible role for `nvidia_gpu_node` hosts). Once running, it
also sets the `nvidia.com/gpu.present` label and the `nvidia.com/gpu` allocatable
resource on the node.

Requires the NVIDIA container runtime to be configured in k3s's containerd. The
`update_packages` role writes a `config.toml.tmpl` that sets the NVIDIA runtime as
default and survives k3s-agent restarts.

### Open WebUI

ChatGPT-style web interface for interacting with LLMs. Authenticates via Dex
(OIDC) with GitHub — emails in `admin_emails` get admin role, those in `viewer_emails` get
user role. Password login is disabled. Connects to both:

- **RKLLama** (Ollama-compatible API) on the RK1 NPU — via `ollamaUrls`
- **llama.cpp** (OpenAI-compatible API) on an NVIDIA GPU — via `openaiBaseApiUrl`

Models from both backends appear merged in the model dropdown. Stores chat history
and user accounts on a static `local-nvme` PV pinned to node04 (5Gi). Resource
limits: 100m/256Mi request, 500m/1Gi limit.

:::{note}
Either backend is optional. The service works with just RKLLama (RK1 cluster),
just llama.cpp (NVIDIA GPU node), or both simultaneously.
:::

RK1 models appear after being pulled
via `rkllama-pull` (see {doc}`/how-to/rkllama-models`). CUDA models appear as soon
as the GGUF file is present on the NFS share and llamacpp has loaded it
(see {doc}`/how-to/llamacpp-models`).

### Open Brain MCP

Standalone MCP (Model Context Protocol) server providing persistent AI memory
for Claude.ai and Claude Code. Authenticates via OAuth 2.1 with GitHub as
identity provider. Connects directly to the Supabase PostgreSQL database for
thought storage and to Supabase Storage (MinIO) for file attachments.

Five tools: `capture_thought` (text-only), `search_thoughts`, `list_thoughts`,
`thought_stats`, `get_attachment` (base64 file retrieval from MinIO).

A local stdio MCP server (`open-brain-cli/`) extends this with
`upload_attachment` and `download_attachment` for Claude Code use.

**Additional manifests:** `additions/open-brain-mcp/`
- `templates/open-brain-mcp-secret.yaml` — SealedSecret for GitHub OAuth credentials, DB URL, and JWT secret

See {doc}`/how-to/open-brain` for deployment and {doc}`/how-to/claude-ai-mcp` for
connecting Claude.ai.

### Sealed Secrets

Bitnami Sealed Secrets controller. Installed in `kube-system` namespace. Decrypts
`SealedSecret` resources into regular Kubernetes Secrets.

### Supabase

Self-hosted Supabase platform providing PostgreSQL, authentication, REST API
(PostgREST), realtime subscriptions, edge functions, storage, and an admin
dashboard (Studio). Used as the backend for Open Brain AI memory.

Components: db, auth, rest, realtime, storage, functions, studio, kong, meta,
minio (10 pods total). All pods scheduled on x86/amd64 nodes.

MinIO provides S3-compatible object storage for file attachments, backed by a
static `local-nvme` PV pinned to nuc2. Studio is protected by OAuth via
oauth2-proxy.

**Additional manifests:** `additions/supabase/`
- `templates/supabase-secret.yaml` — SealedSecret for all Supabase credentials (JWT, DB password, API keys, MinIO credentials)

See {doc}`/how-to/open-brain` for deployment.

## ArgoCD itself

ArgoCD is not in the `kubernetes-services/templates/` directory — it is installed
directly by the Ansible `cluster` role using the OCI Helm chart (v9.4.17). It is the
foundation that all other services depend on.

Login via Dex (GitHub). The built-in admin account is disabled. RBAC maps
emails to `role:admin` or `role:readonly` via `argocd-rbac-cm.yml`.

Access: `argocd.<domain>` (via Cloudflare tunnel) or `kubectl port-forward svc/argocd-server -n argo-cd 8080:8080`.

See {doc}`/explanations/authentication` for details on how Dex is shared
across services.
