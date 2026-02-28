# Kubernetes Services Structure

All cluster services are managed through a single **meta Helm chart** in the
`kubernetes-services/` directory. ArgoCD deploys this chart, and each template
within it becomes an independent ArgoCD Application.

## Directory layout

```
kubernetes-services/
├── Chart.yaml              # Minimal Helm chart metadata
├── values.yaml             # Shared values (repo_branch, oauth2_emails, etc.)
├── templates/              # One ArgoCD Application per service
│   ├── cert-manager.yaml
│   ├── cloudflared.yaml
│   ├── dashboard.yaml      # Headlamp
│   ├── echo.yaml
│   ├── grafana.yaml
│   ├── ingress.yaml
│   ├── kernel-settings.yaml
│   ├── llamacpp.yaml
│   ├── longhorn.yaml
│   ├── nvidia-device-plugin.yaml
│   ├── oauth2-proxy.yaml
│   ├── open-webui.yaml
│   ├── rkllama.yaml
│   └── sealed-secrets.yaml
└── additions/              # Extra manifests per service
    ├── argocd/             # Custom CM for ArgoCD health checks
    ├── cert-manager/       # SealedSecret + ClusterIssuer
    ├── cloudflared/        # Deployment + SealedSecret
    ├── dashboard/          # RBAC for Headlamp
    ├── echo/               # Echo-server manifests
    ├── ingress/            # Reusable ingress sub-chart
    ├── llamacpp/           # NFS volume + GPU config
    ├── longhorn/           # VolumeSnapshotClass
    ├── oauth2-proxy/       # SealedSecret for OAuth config
    └── rkllama/            # DaemonSet + ConfigMap + Ingress + Service
```

## How it works

### The root Application

The Ansible `cluster` role creates a root ArgoCD Application called
`all-cluster-services`. It points at `kubernetes-services/` and passes shared
values via Helm:

- `repo_remote` — Git repository URL
- `repo_branch` — comes from `kubernetes-services/values.yaml` (self-referential)
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
        cluster_domain: "{{ .Values.cluster_domain }}"
        service_name: cert-manager
        service_port: 443
```

### The reusable ingress sub-chart

The `additions/ingress/` directory contains a minimal Helm chart that generates
a standardised Ingress resource. It supports:

- TLS via the `letsencrypt-prod` ClusterIssuer
- Host-based routing (`<service_name>.<cluster_domain>`)
- `basic_auth: true` — nginx basic-auth via the `admin-auth` secret
- `oauth2_proxy: true` — protect with oauth2-proxy authentication gateway
- `ssl_redirect: false` — disable HTTP→HTTPS redirect (default true)
- `ssl_passthrough: true` — TLS passthrough mode (e.g. for ArgoCD)

This avoids duplicating ingress boilerplate across services.

### Plain manifest services

Some services (echo, cloudflared, rkllama) don't use external Helm charts — they
deploy raw Kubernetes manifests directly from `additions/<service>/`. The ArgoCD
Application simply points at the directory.

## Values flow

```mermaid
flowchart TD
    GV["group_vars/all.yml<br/>(Ansible vars)"] -->|"cluster role"| ROOT["Root Application CR<br/>valuesObject"]
    VY["kubernetes-services/values.yaml<br/>(repo_branch)"] -->|"Helm values"| ROOT
    ROOT -->|"{{ .Values.* }}"| CHILD["Child Application templates"]
    CHILD -->|"Service-specific values"| SVC["Deployed services"]
```

Key values propagated to all child apps:

| Value | Source | Purpose |
|-------|--------|---------|
| `repo_remote` | `group_vars/all.yml` | Git repo URL for multi-source apps |
| `repo_branch` | `kubernetes-services/values.yaml` | Branch for `targetRevision` |
| `cluster_domain` | `group_vars/all.yml` | Domain for ingress hosts |
| `domain_email` | `group_vars/all.yml` | Let's Encrypt email |

## Renovate integration

[Renovate](https://docs.renovatebot.com/) monitors `kubernetes-services/templates/*.yaml`
for `targetRevision` fields and automatically creates pull requests when upstream Helm
charts release new versions. See `renovate.json` for the full configuration.
