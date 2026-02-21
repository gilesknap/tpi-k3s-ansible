# Plan: Simplify Cluster + Add RK1 NPU LLM Serving

**Branch:** `llm-simplify` (worktree at `/workspaces/tpi-k3s-llm`)
**Based on:** `add-cloudflared`
**Session date:** 2026-02-21

## Goals

1. Simplify the cluster in preparation for running local LLMs
2. Remove extraneous services (Minecraft, Echo, deprecated Dashboard)
3. Replace archived Kubernetes Dashboard with Headlamp
4. Complete the half-implemented cloudflared tunnel
5. Add RKLLama as a DaemonSet across the 3 RK1 nodes for NPU-accelerated LLM inference

## Hardware Context

| Node | Slot | Type | NVME | Role |
|------|------|------|------|------|
| node01 | 1 | CM4 (4GB) | No | K3s control plane |
| node02 | 2 | RK1 (16GB) | Yes | K3s worker + NPU |
| node03 | 3 | RK1 (16GB) | Yes | K3s worker + NPU |
| node04 | 4 | RK1 (16GB) | Yes | K3s worker + NPU |

Each RK3588 (RK1) has a 6 TOPS NPU (3× dual-core NPU blocks), giving 18 TOPS aggregate.

## LLM Strategy

**Chosen approach: RKLLama DaemonSet (one NPU-accelerated pod per RK1 node)**

- **Why not Ollama:** CPU-only on RK3588. No RKNN/NPU support exists or is planned.
- **Why not distributed single-model:** RKLLM has no multi-node distribution. llama.cpp RPC is
  CPU-only and only helps for models >16B that don't fit on one node.
- **Why RKLLama:** OpenAI/Ollama-compatible HTTP API backed by Rockchip's official RKLLM SDK.
  Full NPU acceleration. Actively maintained (`ghcr.io/notpunchnox/rkllama:main`, ARM64 multi-arch).
  Benchmark: Qwen2.5-1.5B w8a8 → ~16 tok/s per node on NPU (vs ~3-4 tok/s CPU-only).
- **Scaling:** 3 independent RKLLama pods behind a ClusterIP Service = ~3× throughput via round-robin.
- **Context window:** Up to 4096 tokens (RKLLM limit).
- **Model format:** `.rkllm` (not GGUF). Conversion requires x86 `rkllm-toolkit` or pre-converted
  files from HuggingFace (`c01zaut` or `punchnox` user pages).

## Dashboard Decision

The official `kubernetes/dashboard` was **archived January 21, 2026**. Its README explicitly
redirects to **Headlamp** (`kubernetes-sigs/headlamp`):
- Now a Kubernetes SIG UI official project
- ARM64 multi-arch image (`ghcr.io/headlamp-k8s/headlamp`)
- Helm chart at `https://headlamp-k8s.github.io/headlamp/`
- Active (v0.40.1, Feb 2026)
- Drop-in replacement: same Ingress, same TLS pattern

## Task Checklist

- [x] Phase 0: Create git worktree (`llm-simplify` branch at `/workspaces/tpi-k3s-llm`)
- [x] Phase 1a: Delete `kubernetes-services/templates/minecraft.yaml`
- [x] Phase 1b: Delete `argo-cd/argocd-minecraft.yaml` (minecraft AppProject)
- [x] Phase 1c: Remove `minecraft_remote` / `minecraft_branch` from `group_vars/all.yml`
- [x] Phase 1d: Remove `minecraft_*` Helm values from `argo-cd/argo-git-repository.yaml`
- [x] Phase 1e: Delete `kubernetes-services/templates/echo.yaml`
- [x] Phase 1f: Delete `kubernetes-services/additions/echo/` directory
- [x] Phase 1g: Delete stale files: `pb_recover_nvme.yml`, `roles/flash/tasks/recover_nvme_boot.yml`,
  `docs/recover-rk1-maskrom.md` (if they exist) — none existed in llm-simplify branch
- [x] Phase 2a: Rewrite `kubernetes-services/templates/dashboard.yaml` → Headlamp Helm chart
- [x] Phase 2b: Update `kubernetes-services/additions/dashboard/rbac.yaml` for Headlamp SA name
- [x] Phase 3a: Create `kubernetes-services/templates/cloudflared.yaml` ArgoCD Application
- [x] Phase 3b: Fill in ingress rules in `kubernetes-services/additions/cloudflared/values.yaml`
- [x] Phase 3c: Add SealedSecret stub for cloudflared tunnel credentials (live cluster needed)
- [x] Phase 4: Add `kubectl label node` task in `roles/k3s/tasks/worker.yml` for `node-type=rk1`
- [x] Phase 5a: Create `kubernetes-services/additions/rkllama/configmap.yaml` (fix_frequency script)
- [x] Phase 5b: Create `kubernetes-services/additions/rkllama/daemonset.yaml`
- [x] Phase 5c: Create `kubernetes-services/additions/rkllama/service.yaml`
- [x] Phase 5d: Create `kubernetes-services/additions/rkllama/ingress.yaml`
- [x] Phase 5e: Create `kubernetes-services/templates/rkllama.yaml` (ArgoCD Application)
- [x] Phase 5f: Add Ansible task to create `/opt/rkllama/models/` on RK1 nodes

## Manual Prerequisites (require live cluster / offline x86)

- **Cloudflared tunnel token:** Retrieve `TUNNEL_TOKEN` for tunnel `gk2` from the Cloudflare
  Zero Trust dashboard, then seal with `kubeseal`:
  ```
  kubectl create secret generic cloudflared-credentials \
    --namespace cloudflared \
    --from-literal=TUNNEL_TOKEN=<token> \
    --dry-run=client -o yaml | \
    kubeseal --controller-namespace kube-system -o yaml > \
    kubernetes-services/additions/cloudflared/tunnel-secret.yaml
  ```
- **Model files:** Stage `.rkllm` model files to `/opt/rkllama/models/` on each RK1 node.
  Either convert with `rkllm-toolkit` on an x86 Linux machine, or download pre-converted files:
  - HuggingFace search: `c01zaut rk3588` or `punchnox rkllm`
  - Recommended starter: `Qwen2.5-1.5B-Instruct-rk3588-w8a8-opt-1-hybrid-ratio-0.0.rkllm`

## Service Summary (post-simplification)

| Service | Status | Purpose |
|---------|--------|---------|
| NGINX Ingress | Keep | All cluster ingress |
| cert-manager | Keep | Let's Encrypt TLS |
| Longhorn | Keep | Distributed persistent storage (RK1 NVMEs) |
| Sealed Secrets | Keep | Encrypted secrets in git |
| kernel-settings DaemonSet | Keep | Network sysctl tuning |
| Grafana/Prometheus | Keep | Monitoring (NPU/RAM tracking during LLM workloads) |
| Headlamp | New (replaces Dashboard) | K8s web UI |
| cloudflared | Complete | Cloudflare tunnel for external access |
| RKLLama | New | NPU-accelerated LLM serving (OpenAI-compatible API) |
| Minecraft | **Remove** | Personal game server — not needed |
| Echo | **Remove** | Test canary — not needed now |
| kubernetes/dashboard | **Remove** | Archived Jan 2026, replaced by Headlamp |

## Key Files to Touch

```
kubernetes-services/
  templates/
    dashboard.yaml          ← rewrite to Headlamp
    minecraft.yaml          ← DELETE
    echo.yaml               ← DELETE
    cloudflared.yaml        ← CREATE
    rkllama.yaml            ← CREATE
  additions/
    dashboard/rbac.yaml     ← update SA name for Headlamp
    cloudflared/values.yaml ← fill in ingress rules + uncomment secret
    cloudflared/tunnel-secret.yaml  ← CREATE (sealed secret, needs live cluster)
    echo/                   ← DELETE directory
    rkllama/                ← CREATE directory
      configmap.yaml
      daemonset.yaml
      service.yaml
      ingress.yaml
argo-cd/
  argocd-minecraft.yaml     ← DELETE
  argo-git-repository.yaml  ← remove minecraft_* values
group_vars/all.yml          ← remove minecraft_* vars
roles/k3s/tasks/worker.yml  ← add node-type=rk1 label task
roles/cluster/tasks/        ← add rkllama model dir task (new rkllama.yml)
pb_recover_nvme.yml         ← DELETE (stale)
roles/flash/tasks/recover_nvme_boot.yml  ← DELETE (stale)
docs/recover-rk1-maskrom.md ← DELETE (stale)
```

## Deployment Notes

- Deploy with: `ansible-playbook pb_all.yml -e repo_branch=llm-simplify`
- Or override just ArgoCD branch: pass `-e repo_branch=llm-simplify` so ArgoCD tracks this branch
- RKLLama pods will be Pending until `.rkllm` model files are staged on each node's `/opt/rkllama/models/`
- After cluster is up, run the `kubeseal` command above to create the cloudflared tunnel secret
