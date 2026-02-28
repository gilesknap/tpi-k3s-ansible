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
- ArgoCD has the `kubernetes` AppProject with `sourceRepos` restricted to the
  project's GitHub repo and trusted Helm chart registries.

### Service authentication

| Service | Auth method | Notes |
|---------|------------|-------|
| ArgoCD | Username/password | bcrypt hash in `argocd-secret` |
| Grafana | OAuth (GitHub) | via oauth2-proxy + nginx ingress |
| Longhorn | OAuth (GitHub) | via oauth2-proxy + nginx ingress |
| Headlamp | OAuth (GitHub) | via oauth2-proxy + nginx ingress |
| Open WebUI | OAuth (GitHub) | via oauth2-proxy + nginx ingress |
| Echo | None (intentional) | Public test service |
| RKLlama | None (intentional) | Internal LLM API (fronted by Open WebUI) |

See {doc}`/how-to/oauth-setup` for how to configure OAuth.

## Secrets management

### Sealed Secrets

Sensitive values (API tokens, tunnel credentials, OAuth client secrets) are
encrypted using [Sealed Secrets](https://sealed-secrets.netlify.app/) and
stored in Git as `SealedSecret` resources. Only the cluster's sealed-secrets
controller can decrypt them.

Current SealedSecrets:

- `kubernetes-services/additions/cloudflared/tunnel-secret.yaml` — Cloudflare tunnel token
- `kubernetes-services/additions/cert-manager/templates/cloudflare-api-token-secret.yaml` — DNS API token
- `kubernetes-services/additions/oauth2-proxy/oauth2-proxy-secret.yaml` — OAuth client credentials

### Admin password

The `admin-auth` Kubernetes secret is created manually during bootstrap (see
{doc}`/how-to/bootstrap-cluster`). It stores htpasswd credentials used by
Grafana.

## Pod Security Standards

Security contexts are applied at the workload level. See
{doc}`security-hardening` for a detailed breakdown of which workloads run
as non-root, which have read-only root filesystems, and which require
privileged access.

## Container image pinning

All container images are pinned to specific version tags. Renovate bot
monitors for updates and raises PRs automatically. See
{doc}`security-hardening` for the full policy.

## Network security

### Control plane taint

In multi-node clusters, the control plane node has a `NoSchedule` taint. No regular
workloads run on it — only K3s system components (CoreDNS, metrics-server, etcd,
kube-proxy). For single-node clusters the taint is skipped so all workloads can schedule.

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

### NetworkPolicies

NetworkPolicies are not deployed by default. See {doc}`network-policies` for
the rationale and guidance on implementing them if needed.

## TLS everywhere

All ingress endpoints use TLS certificates from Let's Encrypt (production CA):

- Certificates are automatically issued and renewed by cert-manager
- DNS-01 validation via Cloudflare API (works for LAN-only services too)
- HSTS headers are set by ingress-nginx by default
- ArgoCD uses TLS passthrough (handles its own certificate)

## Recommendations

1. **Enable OAuth** — replace basic-auth with GitHub OAuth via oauth2-proxy.
2. **Rotate SealedSecrets periodically** — re-seal with fresh values.
3. **Back up the sealed-secrets key** — without it, a cluster rebuild requires re-creating all secrets.
4. **Keep nodes updated** — `unattended-upgrades` handles security patches automatically.
5. **Monitor for alerts** — Prometheus Alertmanager captures security-relevant events.
6. **Review the production checklist** — see {doc}`/reference/production-checklist`.
