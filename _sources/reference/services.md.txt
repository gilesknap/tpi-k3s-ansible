# Services Reference

All services deployed by ArgoCD, with their chart sources, versions, and access methods.

## Service catalogue

| Service | Chart / Source | Version | Namespace | Ingress URL | Auth | Purpose |
|---------|---------------|---------|-----------|-------------|------|---------|
| cert-manager | `jetstack/cert-manager` | v1.19.4 | `cert-manager` | — | — | TLS certificate management |
| cloudflared | Plain manifests | 2026.2.0 | `cloudflared` | — | — | Cloudflare tunnel connector |
| echo | Plain manifests | 0.9.2 | `echo` | `echo.<domain>` | None | HTTP echo test service |
| Grafana + Prometheus | `prometheus-community/kube-prometheus-stack` | 82.4.1 | `monitoring` | `grafana.<domain>` | OAuth | Monitoring and dashboards |
| Headlamp | `headlamp/headlamp` | 0.40.0 | `headlamp` | `headlamp.<domain>` | OAuth | Kubernetes dashboard |
| ingress-nginx | `ingress-nginx/ingress-nginx` | 4.14.3 | `ingress-nginx` | — | — | Ingress controller |
| kernel-settings | Inline DaemonSet | — | `kube-system` | — | — | Sysctl tuning for performance |
| Longhorn | `longhorn/longhorn` | 1.11.0 | `longhorn` | `longhorn.<domain>` | OAuth | Distributed block storage |
| oauth2-proxy | `oauth2-proxy/oauth2-proxy` | 7.12.10 | `oauth2-proxy` | `oauth2.<domain>` | GitHub | OAuth authentication proxy |
| RKLlama | Helm chart (local) | 0.0.4 | `rkllama` | `rkllama.<domain>` | None | NPU-accelerated LLM server (Rockchip RK1) |
| llama.cpp | Helm chart (local) | — | `llamacpp` | `llamacpp.<domain>` | — | CUDA-accelerated LLM server (NVIDIA GPU) |
| NVIDIA device plugin | `nvidia/nvidia-device-plugin` | 0.18.2 | `nvidia-device-plugin` | — | — | Advertises `nvidia.com/gpu` resources to the scheduler |
| Open WebUI | `open-webui/open-webui` | 12.5.0 | `open-webui` | `open-webui.<domain>` | OAuth | ChatGPT-style UI backed by RKLLama and/or llama.cpp |
| Open Brain MCP | Helm chart (local) | — | `open-brain-mcp` | `brain.<domain>` | OAuth 2.1 (GitHub) | Standalone MCP server for AI memory |
| Sealed Secrets | `bitnami-labs/sealed-secrets` | 2.18.3 | `kube-system` | — | — | Encrypted secrets in Git |
| Supabase | `supabase-community/supabase-kubernetes` | — | `supabase` | `supabase.<domain>`, `supabase-api.<domain>` | OAuth (Studio), x-brain-key (API) | Self-hosted backend-as-a-service platform |

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
`2026.2.0`.

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
Alertmanager for alerts. Protected by OAuth via oauth2-proxy. Longhorn persistent
volumes for data (30Gi Grafana, 40Gi Prometheus). Grafana resource limits:
100m/256Mi request, 500m/512Mi limit.

Uses `ServerSideApply=true` sync option due to large CRDs.

### Headlamp

Modern Kubernetes dashboard. Protected by OAuth via oauth2-proxy. Uses a
ServiceAccount with `cluster-admin` binding and a long-lived token Secret.
Resource limits: 50m/128Mi request, 200m/256Mi limit.

**Additional manifests:** `additions/dashboard/`
- `rbac.yaml` — ServiceAccount, ClusterRoleBinding, long-lived token Secret

### ingress-nginx

NGINX ingress controller. Admission webhooks are disabled. Resource limits:
100m/256Mi request, 500m/512Mi limit. PodDisruptionBudget: minAvailable 1.

### kernel-settings

DaemonSet that applies system tuning on all nodes:
- Sets `rmem_max` and `wmem_max` to 7500000 (network buffers)
- Blacklists Longhorn iSCSI devices from multipathd

All busybox images pinned to `1.37`.

### Longhorn

Distributed block storage with replication, snapshots, and backup support. Includes a
`VolumeSnapshotClass` for Kubernetes volume snapshots. Web UI protected with OAuth via
oauth2-proxy. ServiceMonitor enabled for Prometheus metrics.

**Additional manifests:** `additions/longhorn/`
- `volume-snapshot-class.yaml` — VolumeSnapshotClass (default, Delete policy)

### oauth2-proxy

Lightweight OAuth authentication proxy. Redirects unauthenticated users to GitHub
for login. Integrated with nginx ingress annotations. Resource limits: 10m/64Mi
request, 100m/128Mi limit.

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

ChatGPT-style web interface for interacting with LLMs. Protected by OAuth via
oauth2-proxy. Connects to both:

- **RKLLama** (Ollama-compatible API) on the RK1 NPU — via `ollamaUrls`
- **llama.cpp** (OpenAI-compatible API) on an NVIDIA GPU — via `openaiBaseApiUrl`

Models from both backends appear merged in the model dropdown. Stores chat history
and user accounts in a Longhorn-backed 5Gi volume. Resource limits: 100m/256Mi
request, 500m/1Gi limit.

:::{note}
Either backend is optional. The service works with just RKLLama (RK1 cluster),
just llama.cpp (NVIDIA GPU node), or both simultaneously.
:::

The first user to register becomes the admin. RK1 models appear after being pulled
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
Longhorn PVC. Studio is protected by OAuth via oauth2-proxy.

**Additional manifests:** `additions/supabase/`
- `templates/supabase-secret.yaml` — SealedSecret for all Supabase credentials (JWT, DB password, API keys, MinIO credentials)

See {doc}`/how-to/open-brain` for deployment.

## ArgoCD itself

ArgoCD is not in the `kubernetes-services/templates/` directory — it is installed
directly by the Ansible `cluster` role using the OCI Helm chart (v7.8.3). It is the
foundation that all other services depend on.

Access: `argocd.<domain>` (SSL passthrough) or `kubectl port-forward svc/argocd-server -n argo-cd 8080:443`.
