# Services Reference

All services deployed by ArgoCD, with their chart sources, versions, and access methods.

## Service catalogue

| Service | Chart / Source | Version | Namespace | Ingress URL | Purpose |
|---------|---------------|---------|-----------|-------------|---------|
| cert-manager | `jetstack/cert-manager` | v1.19.3 | `cert-manager` | — | TLS certificate management |
| cloudflared | Plain manifests | — | `cloudflared` | — | Cloudflare tunnel connector |
| echo | Plain manifests | — | `echo` | `echo.<domain>` | HTTP echo test service |
| Grafana + Prometheus | `prometheus-community/kube-prometheus-stack` | 82.2.0 | `monitoring` | `grafana.<domain>` | Monitoring and dashboards |
| Headlamp | `headlamp/headlamp` | 0.40.0 | `headlamp` | `headlamp.<domain>` | Kubernetes dashboard |
| ingress-nginx | `ingress-nginx/ingress-nginx` | 4.14.3 | `ingress-nginx` | — | Ingress controller |
| kernel-settings | Inline DaemonSet | — | `kube-system` | — | Sysctl tuning for performance |
| Longhorn | `longhorn/longhorn` | 1.11.0 | `longhorn` | `longhorn.<domain>` | Distributed block storage |
| RKLlama | Helm chart (local) | — | `rkllama` | `rkllama.<domain>` | NPU-accelerated LLM server |
| Sealed Secrets | `bitnami-labs/sealed-secrets` | 2.18.1 | `kube-system` | — | Encrypted secrets in Git |

## Service details

### cert-manager

Manages TLS certificates via Let's Encrypt. Uses DNS-01 validation through the
Cloudflare API. Includes a `ClusterIssuer` (`letsencrypt-prod`) and a SealedSecret
for the Cloudflare API token.

**Additional manifests:** `additions/cert-manager/`
- `cloudflare-api-token-secret.yaml` — SealedSecret for DNS API token
- `issuer-letsencrypt-prod.yaml` — ClusterIssuer for production Let's Encrypt

### cloudflared

Outbound Cloudflare tunnel connector. Runs 2 replicas for availability. Reads the
tunnel token from a SealedSecret. Non-root, read-only rootfs.

**Additional manifests:** `additions/cloudflared/`
- `deployment.yaml` — 2-replica Deployment
- `tunnel-secret.yaml` — SealedSecret for tunnel token

### echo

Simple HTTP echo service ([ealen/echo-server](https://github.com/Ealenn/Echo-Server))
for testing ingress, TLS, and headers. Exposed publicly via Cloudflare tunnel with
`ssl-redirect: false`.

**Additional manifests:** `additions/echo/`
- `manifests.yaml` — Deployment, Service, and Ingress

### Grafana + Prometheus (kube-prometheus-stack)

Full monitoring stack: Prometheus for metrics collection, Grafana for dashboards,
Alertmanager for alerts. Uses `admin-auth` existingSecret for Grafana login. Longhorn
persistent volumes for data (30Gi Grafana, 40Gi Prometheus).

Uses `ServerSideApply=true` sync option due to large CRDs.

### Headlamp

Modern Kubernetes dashboard. Uses token-based authentication (not the shared admin
password). Requires a ServiceAccount with `cluster-admin` binding.

**Additional manifests:** `additions/dashboard/`
- `rbac.yaml` — ServiceAccount, ClusterRoleBinding, long-lived token Secret

### ingress-nginx

NGINX ingress controller. Admission webhooks are disabled. Replaces K3s's default
Traefik.

### kernel-settings

DaemonSet that applies system tuning on all nodes:
- Sets `rmem_max` and `wmem_max` to 7500000 (network buffers)
- Blacklists Longhorn iSCSI devices from multipathd

### Longhorn

Distributed block storage with replication, snapshots, and backup support. Includes a
`VolumeSnapshotClass` for Kubernetes volume snapshots. Web UI protected with nginx
basic-auth. ServiceMonitor enabled for Prometheus metrics.

**Additional manifests:** `additions/longhorn/`
- `volume-snapshot-class.yaml` — VolumeSnapshotClass (default, Delete policy)

### RKLlama

NPU-accelerated LLM inference server for Rockchip RK1 nodes. Runs as a DaemonSet on
nodes labelled `node-type: rk1`. Requires privileged access to `/dev/rknpu`. Models
are stored on an NFS PersistentVolume so they are shared across all RK1 nodes and
persist outside the cluster.

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
changing (see [Variables Reference](#argocd-helm-values).

### Sealed Secrets

Bitnami Sealed Secrets controller. Installed in `kube-system` namespace. Decrypts
`SealedSecret` resources into regular Kubernetes Secrets.

## ArgoCD itself

ArgoCD is not in the `kubernetes-services/templates/` directory — it is installed
directly by the Ansible `cluster` role using the OCI Helm chart (v7.8.3). It is the
foundation that all other services depend on.

Access: `argocd.<domain>` (SSL passthrough) or `kubectl port-forward svc/argocd-server -n argo-cd 8080:443`.
