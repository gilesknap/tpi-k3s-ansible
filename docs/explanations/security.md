# Security Model

This page describes the security measures in place across the cluster.

## Authentication and access control

### SSH access

- All nodes use **key-based SSH authentication** only (password auth is disabled).
- A dedicated `ansible` user is created on each node with passwordless sudo.
- The SSH keypair is stored in `pub_keys/ansible_rsa.pub` (public key only in Git).
- The private key lives on the operator's workstation and is mounted into the
  devcontainer via a Docker volume.

### Kubernetes RBAC

- The control plane uses the default K3s RBAC configuration.
- Headlamp has a dedicated `headlamp-admin` ServiceAccount bound to `cluster-admin`
  with a long-lived token Secret for dashboard access.
- ArgoCD has the `kubernetes` AppProject allowing access to all namespaces and
  cluster-scoped resources.

### Service authentication

| Service | Auth method | Notes |
|---------|------------|-------|
| ArgoCD | Username/password | bcrypt hash in `argocd-secret` |
| Grafana | Username/password | `admin-auth` existingSecret |
| Longhorn | HTTP basic-auth | nginx annotation + `admin-auth` secret |
| Headlamp | Kubernetes token | `kubectl create token headlamp-admin` |
| Echo | None (intentional) | Public test service |
| RKLlama | None (intentional) | Internal LLM service |

## Secrets management

### Sealed Secrets

Sensitive values (API tokens, tunnel credentials) are encrypted using
[Sealed Secrets](https://sealed-secrets.netlify.app/) and stored in Git as
`SealedSecret` resources. Only the cluster's sealed-secrets controller can decrypt
them.

Current SealedSecrets:

- `kubernetes-services/additions/cloudflared/tunnel-secret.yaml` — Cloudflare tunnel token
- `kubernetes-services/additions/cert-manager/cloudflare-api-token-secret.yaml` — DNS API token

### Admin password

The shared admin password is passed via the Ansible command line
(`-e admin_password=...`) and injected into the ArgoCD root Application's Helm values.
It is **not** stored in Git.

The `admin-auth` Kubernetes secret (created manually during bootstrap) stores both
htpasswd and plain-text forms for different services.

## Network security

### Control plane taint

The control plane node has a `NoSchedule` taint. No regular workloads run on it —
only K3s system components (CoreDNS, metrics-server, etcd, kube-proxy).

### Cloudflare protection

Services exposed via the Cloudflare tunnel benefit from:

- **WAF** — Web Application Firewall with managed rulesets
- **DDoS protection** — automatic layer 3/4/7 mitigation
- **Bot management** — challenge suspicious traffic
- **Rate limiting** — configurable per-hostname rules

### No inbound firewall ports

The Cloudflare tunnel uses an **outbound-only** connection from the `cloudflared` pod.
No inbound ports need to be opened on your router for public-facing services.

### LAN isolation

LAN-only services (ArgoCD, Grafana, Longhorn, Headlamp) use grey-cloud DNS records
pointing to private RFC-1918 IP addresses. They are unreachable from outside the
local network.

## TLS everywhere

All ingress endpoints use TLS certificates from Let's Encrypt (production CA):

- Certificates are automatically issued and renewed by cert-manager
- DNS-01 validation via Cloudflare API (works for LAN-only services too)
- HSTS headers are set by ingress-nginx by default
- ArgoCD uses TLS passthrough (handles its own certificate)

## Recommendations

1. **Use a strong admin password** — shared across Grafana, Longhorn, and ArgoCD.
2. **Rotate SealedSecrets periodically** — re-seal with fresh values.
3. **Back up the sealed-secrets key** — without it, a cluster rebuild requires re-creating all secrets.
4. **Keep nodes updated** — `unattended-upgrades` handles security patches automatically.
5. **Monitor for alerts** — Prometheus Alertmanager captures security-relevant events.
