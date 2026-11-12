# Kubernetes Services Structure

All cluster services are managed through a single **meta Helm chart** in the
`kubernetes-services/` directory. ArgoCD deploys this chart, and each template
within it becomes an independent ArgoCD Application.

## Directory layout

```
kubernetes-services/
├── Chart.yaml              # Minimal Helm chart metadata
├── values.yaml             # Shared values (repo_branch, admin_emails, etc.)
├── templates/              # One ArgoCD Application per service
│   ├── argocd-monitor.yaml
│   ├── backups.yaml
│   ├── cert-manager.yaml
│   ├── cloudflared.yaml
│   ├── coredns.yaml
│   ├── dashboard.yaml      # Headlamp
│   ├── echo.yaml
│   ├── grafana.yaml        # kube-prometheus-stack
│   ├── home.yaml
│   ├── ingress.yaml        # ingress-nginx
│   ├── intel-gpu-plugin.yaml # Intel iGPU device plugin
│   ├── jellyfin.yaml
│   ├── kernel-settings.yaml
│   ├── kured.yaml
│   ├── kyverno.yaml        # disabled by default
│   ├── local-storage.yaml
│   ├── minecraft.yaml      # Minecraft dashboard (OCI chart, optional)
│   ├── nfs-csi.yaml
│   ├── ntfy.yaml
│   ├── nvidia-device-plugin.yaml
│   ├── oauth2-proxy.yaml
│   ├── scrap.yaml
│   ├── sealed-secrets.yaml
│   ├── system-upgrade.yaml
│   └── vps-relay.yaml      # frpc + Tailscale relay to a VPS (optional)
└── additions/              # Extra manifests per service
    ├── argocd/             # Dex SealedSecret
    ├── argocd-monitor/     # OAuth SealedSecret
    ├── backups/            # CronJobs + single NFS PV for per-app backups
    ├── cert-manager/       # SealedSecret + ClusterIssuer + wildcard Certificate
    ├── cloudflared/        # Deployment + SealedSecret
    ├── coredns/            # CoreDNS HA manifests
    ├── echo/               # Echo-server manifests
    ├── grafana/            # Alert rules, ServiceMonitor, SealedSecrets
    ├── home/               # Landing page
    ├── ingress/            # Reusable ingress sub-chart
    ├── intel-gpu-plugin/   # Vendored Intel GPU plugin DaemonSet + patch
    ├── jellyfin/           # Config PVC, media NFS volume, seed scripts
    ├── k3s-upgrade-plans/  # system-upgrade-controller Plans
    ├── kernel-settings/    # Sysctl DaemonSet
    ├── local-storage/      # local-nvme StorageClass + static per-workload PVs
    ├── ntfy/               # Local ntfy chart + SealedSecret
    ├── oauth2-proxy/       # SealedSecret for OAuth config
    ├── scrap/              # NFS volumes, /mcp Ingress, SealedSecrets
    ├── system-upgrade-controller/  # Vendored upstream release manifests
    └── vps-relay/          # Tailscale + frpc Deployment, generated frpc.toml
```

## How it works

### The root Application

The Ansible `cluster` role creates a root ArgoCD Application called
`all-cluster-services`. It points at `kubernetes-services/` and passes shared
values via Helm:

- `repo_remote` — Git repository URL
- `repo_branch` — from `group_vars/all.yml` (or `-e repo_branch=`), passed in by the
  root Application; it overrides the default in `kubernetes-services/values.yaml`
- `cluster_domain` — domain name for ingress hosts
- `domain_email` — for Let's Encrypt registration

### Template rendering

ArgoCD renders the Helm chart. Each file in `templates/` produces an ArgoCD
`Application` resource. These are **child apps** — each one independently manages
its own service lifecycle.

### Multi-source Applications

Most services use the **multi-source** pattern — combining an external Helm chart
with local additions from this repo:

```yaml
sources:
  # Source 1: External Helm chart
  - repoURL: https://charts.jetstack.io
    targetRevision: "v1.19.3"
    chart: cert-manager
    helm:
      valuesObject:
        crds:
          enabled: true

  # Source 2: Local additions (SealedSecrets, ClusterIssuers, etc.)
  - repoURL: "{{ .Values.repo_remote }}"
    targetRevision: "{{ .Values.repo_branch }}"
    path: kubernetes-services/additions/cert-manager

  # Source 3: Reusable ingress sub-chart (optional)
  - repoURL: "{{ .Values.repo_remote }}"
    targetRevision: "{{ .Values.repo_branch }}"
    path: kubernetes-services/additions/ingress
    helm:
      valuesObject:
        name: my-service          # host is my-service.<cluster_domain>
        cluster_domain: "{{ .Values.cluster_domain }}"
        service_name: my-service
        service_port: 80
```

### The reusable ingress sub-chart

The `additions/ingress/` directory contains a minimal Helm chart that generates
a standardised Ingress resource. It supports:

- `name` (required) — the Ingress is `<name>-ingress` with host
  `<name>.<cluster_domain>`
- TLS via the cluster wildcard certificate (`cert-manager/wildcard-tls`),
  served by ingress-nginx as its default
- `basic_auth: true` — nginx basic-auth via the `admin-auth` secret
- `oauth2_proxy: true` — protect with oauth2-proxy authentication gateway
- `ssl_redirect: false` — disable HTTP→HTTPS redirect (default true)
- `service_port: 443` — talks HTTPS to the backend; TLS still terminates at
  ingress-nginx (the template's `ssl-passthrough` annotation has no effect,
  as the controller does not run with `--enable-ssl-passthrough`)
- `extra_annotations` — a map of extra annotations to add to the Ingress

This avoids duplicating ingress boilerplate across services.

### Plain manifest services

Some services (echo, cloudflared) don't use external Helm charts — they
deploy raw Kubernetes manifests directly from `additions/<service>/`. The ArgoCD
Application simply points at the directory.

## Values flow

```mermaid
flowchart TD
    GV["group_vars/all.yml<br/>(Ansible vars)"] -->|"cluster role"| ROOT["Root Application CR<br/>valuesObject"]
    VY["kubernetes-services/values.yaml<br/>(defaults, admin_emails, toggles)"] -->|"Helm values"| ROOT
    ROOT -->|"{{ .Values.* }}"| CHILD["Child Application templates"]
    CHILD -->|"Service-specific values"| SVC["Deployed services"]
```

Key values propagated to all child apps:

| Value | Source | Purpose |
|-------|--------|---------|
| `repo_remote` | `group_vars/all.yml` | Git repo URL for multi-source apps |
| `repo_branch` | `group_vars/all.yml` (or `-e repo_branch=`) | Branch for `targetRevision` |
| `cluster_domain` | `group_vars/all.yml` | Domain for ingress hosts |
| `domain_email` | `group_vars/all.yml` | Let's Encrypt email |

## Storage layer: `local-storage` and `backups`

Two special services implement the cluster's stateful-data strategy:

- **`local-storage`** (`templates/local-storage.yaml`,
  `additions/local-storage/`) — creates the `local-nvme` `StorageClass`
  (`no-provisioner`, `WaitForFirstConsumer`, `Retain`) plus one static
  `PersistentVolume` per stateful workload, each pre-bound to the
  consuming `PersistentVolumeClaim` via `spec.claimRef` and pinned to a
  specific node via `spec.nodeAffinity`. Sync wave `-5` ensures the SC
  and PVs exist before the stateful charts try to create their PVCs.
  On-disk backing lives at `/home/k8s-data/*` (nuc2) and
  `/var/lib/k8s-data/*` (RK1 nodes) — directories created idempotently
  by the `k8s_data_dirs` Ansible role and **preserved by default** on
  decommission. For the authoritative per-workload directory → node →
  owner mapping, and the opt-in `-e wipe_local_data=true` flag that
  removes them, see the `k8s_data_dirs` section of
  {doc}`ansible-roles`.

- **`backups`** (`templates/backups.yaml`, `additions/backups/`) — one
  namespace, one static NFS `PersistentVolume` pointing at
  `<nas>:/bigdisk/k8s-cluster`, one namespace-scoped `PVC`, and a fleet
  of `CronJob`s (one daily + one weekly per stateful app). Each CronJob
  mounts the shared PVC with a workload-specific `subPath` so it only
  sees `backups/<app>/{,weekly}/`. The NFS share itself is created
  manually on the NAS via {doc}`../how-to/nas-setup` — Ansible has no
  access to the NAS.

Together these give you per-rebuild data survival (local PVs) **plus**
off-cluster point-in-time backups (NFS CronJobs), without the
operational overhead of a replicated CSI driver.

## Renovate integration

[Renovate](https://docs.renovatebot.com/) monitors `kubernetes-services/templates/*.yaml`
for `targetRevision` fields and automatically creates pull requests when upstream Helm
charts release new versions. See `renovate.json` for the full configuration.
