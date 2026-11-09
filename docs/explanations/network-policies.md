# Network Policies

This page explains Kubernetes NetworkPolicies and how they could be applied
to this cluster. There is **no cluster-wide default-deny**: the maintenance
overhead outweighs the benefit for a single-admin homelab. A few services
ship their own policies instead:

- **scrap** admits only `ingress-nginx`, and its public pages site in the
  `scrap-public` namespace has a second policy (see {doc}`/how-to/scrap`).
- **ntfy** admits only `ingress-nginx` and in-cluster publishers such as
  Alertmanager (see {doc}`/how-to/ntfy`).
- **minecraft** limits the worlds' RCON ports to LAN sources (see
  {doc}`/how-to/minecraft`).
- **cloudflared** denies all inbound traffic to its pods, since the tunnel
  only dials out (see {doc}`/how-to/cloudflare-tunnel`).

## What are NetworkPolicies?

NetworkPolicies are Kubernetes resources that control pod-to-pod and
pod-to-external network traffic. Without any policies, all pods can
communicate freely (Kubernetes default). Adding a policy restricts traffic
to only what is explicitly allowed.

## Default-deny pattern

The standard approach is:

1. Apply a **default-deny** policy to each namespace (blocks all ingress).
2. Add **explicit allow** rules for legitimate traffic flows.

Example default-deny policy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

Example allow rule (let ingress-nginx reach Grafana):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-to-grafana
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: grafana
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 3000
```

## Traffic flows in this cluster

If you wanted to implement NetworkPolicies, the key traffic flows to allow
would be:

| From | To | Port | Purpose |
|------|------|------|---------|
| `ingress-nginx` | all service namespaces | service ports | External access |
| `monitoring` (Prometheus) | all namespaces | metrics ports | Scraping |
| `ingress-nginx` | `scrap` | 80 | Only allowed source; scrap ships its own NetworkPolicy (see {doc}`/how-to/scrap`) |
| `ingress-nginx` | `scrap-public` (nginx) | 8080 | The public pages site at `pages.<domain>`; only allowed source (`public.networkPolicy.webFrom`) |
| `scrap` (scrap's pod) | `scrap-public` (receiver) | 8081 | scrap pushes public pages; only allowed source. The namespace has no egress at all |
| `cert-manager` | external | 443 | ACME DNS-01 |
| `cloudflared` | `ingress-nginx` | 80/443 | Tunnel traffic |
| *(none)* | `cloudflared` | — | No inbound traffic; cloudflared ships a deny-all ingress policy (the kubelet probe from the pod's node is still admitted) |
| `argo-cd` | all namespaces | various | GitOps sync |

## When to add NetworkPolicies

Consider deploying NetworkPolicies if:

- The cluster becomes **multi-tenant** (multiple users or teams).
- Services are exposed to the **public internet** without Cloudflare.
- You need to meet a **compliance requirement** (e.g. PCI-DSS, SOC2).
- A workload runs **untrusted code** (e.g. user-submitted jobs).

For a single-admin homelab behind Cloudflare, the security benefit is
marginal and the operational overhead (debugging blocked connections,
maintaining rules as services change) is significant.

## CNI requirements

K3s ships with Flannel as the default CNI, and enforces NetworkPolicies
with an embedded network policy controller (kube-router's), enabled unless
K3s runs with `--disable-network-policy`. That controller always admits
traffic from a pod's own node, so kubelet liveness and readiness probes keep
working under a deny-all ingress policy. Switch to Calico or Cilium only if
you need features beyond standard NetworkPolicy.
