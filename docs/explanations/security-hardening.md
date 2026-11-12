# Security Hardening

This page describes the security hardening measures applied to the cluster
and the principles behind them.

## Pod Security Standards

Kubernetes defines three Pod Security Standards: Privileged, Baseline, and
Restricted. This cluster applies security contexts at the individual
workload level rather than enforcing a cluster-wide standard, because some
workloads (such as kernel tuning) require privileged access.

### Security context summary

| Workload | runAsNonRoot | readOnlyRootFilesystem | Privileged | Reason |
|----------|-------------|----------------------|-----------|--------|
| cloudflared | Yes (65532) | Yes | No | Network-only, no special access needed |
| echo | Yes (65534) | Yes | No | Stateless test service |
| kernel-settings | — | — | Yes | Needs to set host sysctls |

## Container image pinning

All container images are pinned to specific version tags rather than
`latest` or branch tags. This ensures:

- **Reproducibility** — the same image runs in every deployment.
- **Auditability** — you can verify exactly which version is running.
- **Stability** — an upstream push to `latest` cannot break your cluster.

Renovate bot monitors all pinned images and raises PRs when new versions
are available.

## RBAC principles

### Headlamp dashboard

Headlamp is gated by the cluster-wide oauth2-proxy (`admin_emails` only).
Users then paste a token for the `headlamp` ServiceAccount
(`just headlamp-token`), which the chart binds to `cluster-admin`, so anyone
past oauth2-proxy has full cluster access.

### ArgoCD project

The `kubernetes` AppProject restricts `sourceRepos` to the project's
GitHub repository and the specific Helm chart registries used by the
cluster services. This prevents an attacker who gains ArgoCD access from
deploying arbitrary manifests from untrusted repositories.

## Secret management

- All sensitive values are stored as SealedSecrets (encrypted in Git).
- The ArgoCD admin account is disabled; all logins go through Dex (GitHub).
- The `admin-auth` secret (used by Grafana and basic-auth services) is
  created manually during bootstrap and not stored in Git.

## Secret rotation

To rotate secrets:

1. Generate new credentials.
2. Re-seal with `kubeseal` (see {doc}`/how-to/manage-sealed-secrets`).
3. Commit and push — ArgoCD applies the new SealedSecret automatically.
4. Restart affected pods to pick up the new secret values.

## NetworkPolicies

See {doc}`network-policies` for a discussion of NetworkPolicies and when
to deploy them.
