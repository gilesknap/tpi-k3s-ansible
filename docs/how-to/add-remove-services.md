# Add or Remove Services

All cluster services are managed by ArgoCD through the `kubernetes-services/` Helm chart.
Each service is defined by an ArgoCD `Application` template in `kubernetes-services/templates/`.

## How services are deployed

```
kubernetes-services/
├── Chart.yaml              # Meta Helm chart (deployed by ArgoCD root app)
├── values.yaml             # Shared values (repo_branch, etc.)
├── templates/              # One ArgoCD Application per service
│   ├── cert-manager.yaml
│   ├── grafana.yaml
│   ├── ingress.yaml
│   └── ...
└── additions/              # Extra manifests per service
    ├── cert-manager/
    ├── echo/
    ├── ingress/            # Reusable ingress sub-chart
    └── ...
```

ArgoCD renders each template as a child `Application` that independently syncs its
Helm chart or raw manifests. All apps auto-sync with prune and self-heal enabled.

## Add a new service

### Step 1: Create the ArgoCD Application template

Create a new YAML file in `kubernetes-services/templates/`. Use an existing service
as a starting point — `echo.yaml` is the simplest example:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argo-cd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: kubernetes
  destination:
    server: https://kubernetes.default.svc
    namespace: my-service
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  sources:
    # Option A: Helm chart from a repository
    - repoURL: https://charts.example.com
      targetRevision: "1.0.0"
      chart: my-chart
      helm:
        valuesObject:
          key: value

    # Option B: Raw manifests from this repo
    - repoURL: {{ "{{" }} .Values.repo_remote {{ "}}" }}
      targetRevision: {{ "{{" }} .Values.repo_branch {{ "}}" }}
      path: kubernetes-services/additions/my-service
```

Key fields:

- **`metadata.name`** — unique name for the ArgoCD Application
- **`spec.destination.namespace`** — Kubernetes namespace for the service
- **`syncPolicy.syncOptions`** — include `CreateNamespace=true` so ArgoCD creates
  the namespace automatically
- **`sources`** — use a Helm chart, raw manifests from the repo, or both (multi-source)

### Step 2: Add extra manifests (optional)

If the service needs additional Kubernetes resources beyond what the Helm chart provides
(RBAC, ConfigMaps, Secrets, etc.), create them in
`kubernetes-services/additions/my-service/`:

```
kubernetes-services/additions/my-service/
├── rbac.yaml
├── configmap.yaml
└── ...
```

Reference this directory as an additional source in the Application template (see
"Option B" above).

### Step 3: Add an ingress (optional)

For services that need HTTP/HTTPS ingress, use the reusable ingress sub-chart at
`kubernetes-services/additions/ingress/`. Add it as an additional source:

```yaml
- repoURL: {{ "{{" }} .Values.repo_remote {{ "}}" }}
  targetRevision: {{ "{{" }} .Values.repo_branch {{ "}}" }}
  path: kubernetes-services/additions/ingress
  helm:
    valuesObject:
      cluster_domain: {{ "{{" }} .Values.cluster_domain {{ "}}" }}
      service_name: my-service
      service_port: 8080
      # Optional:
      # basic_auth: true     # Enable nginx basic-auth (uses admin-auth secret)
```

The ingress sub-chart creates a standard Ingress resource with:

- TLS using the `letsencrypt-prod` ClusterIssuer
- Host-based routing (`my-service.<cluster_domain>`)
- Optional nginx basic-auth

### Step 4: Commit and push

```bash
git add kubernetes-services/
git commit -m "Add my-service to cluster"
git push
```

ArgoCD detects the change and creates the new Application automatically.

## Remove a service

### Step 1: Delete the template

```bash
rm kubernetes-services/templates/my-service.yaml
```

### Step 2: Delete any additions

```bash
rm -rf kubernetes-services/additions/my-service/
```

### Step 3: Commit and push

```bash
git add -A
git commit -m "Remove my-service from cluster"
git push
```

ArgoCD's prune policy will automatically delete all resources belonging to the removed
Application, including its namespace if it was created by `CreateNamespace=true`.

## Multi-source applications

Most services in this project use multi-source Applications — combining a Helm chart
from an external repository with local additions from this repo. This pattern is used
for services like `cert-manager`, `grafana`, and `ingress-nginx`.

Example from `grafana.yaml` (simplified):

```yaml
sources:
  # 1. The Helm chart
  - repoURL: https://prometheus-community.github.io/helm-charts
    targetRevision: "82.2.0"
    chart: kube-prometheus-stack
    helm:
      valuesObject:
        grafana:
          adminUser: admin
          admin:
            existingSecret: admin-auth
            userKey: user
            passwordKey: password

  # 2. Local additions (ingress)
  - repoURL: "{{ .Values.repo_remote }}"
    targetRevision: "{{ .Values.repo_branch }}"
    path: kubernetes-services/additions/ingress
    helm:
      valuesObject:
        cluster_domain: "{{ .Values.cluster_domain }}"
        service_name: grafana-prometheus
        service_port: 80
```

## Renovate integration

The project uses [Renovate](https://docs.renovatebot.com/) to automatically create pull
requests when Helm chart versions are updated upstream. See `renovate.json` for the
configuration. Renovate monitors `kubernetes-services/templates/*.yaml` for ArgoCD
Application `targetRevision` fields.
