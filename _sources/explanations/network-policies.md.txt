# Network Policies

This page explains Kubernetes NetworkPolicies and how they could be applied
to this cluster. NetworkPolicies are **not deployed** by default because
the maintenance overhead outweighs the benefit for a single-admin homelab.

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
| `open-webui` | `rkllama` | 8080 | LLM API |
| `open-webui` | `llamacpp` | 8080 | LLM API |
| `cert-manager` | external | 443 | ACME DNS-01 |
| `cloudflared` | `ingress-nginx` | 80/443 | Tunnel traffic |
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

K3s ships with Flannel as the default CNI. Flannel supports NetworkPolicy
enforcement via the `kube-router` backend. If you need NetworkPolicies,
you may need to switch to Calico or Cilium. Check the K3s documentation
for CNI configuration options.
