# Production Readiness Checklist

Use this checklist when setting up a new cluster or auditing an existing one.

## Infrastructure

- [ ] All nodes flashed with the target Ubuntu version
- [ ] NVMe root filesystem migration completed (if applicable)
- [ ] K3s installed and all nodes in `Ready` state
- [ ] Control plane taint applied (multi-node clusters)

## DNS and TLS

- [ ] Domain delegated to Cloudflare nameservers
- [ ] Cloudflare API token created with `Zone:DNS:Edit` permission
- [ ] API token SealedSecret committed to Git
- [ ] cert-manager deployed and ClusterIssuer configured
- [ ] All certificates showing `READY: True` (`kubectl get certificate -A`)
- [ ] Grey-cloud A records created for LAN-only services

## Cloudflare tunnel

- [ ] Tunnel, hostnames, Access apps and WAF rules applied with `just cf-apply`
  (see {doc}`/how-to/cloudflare-as-code`)
- [ ] Tunnel token sealed with `just cf-seal-tunnel-token` and committed to Git
- [ ] cloudflared deployment running (2 replicas, on different nodes)
- [ ] WAF skip rule for SSH hostname (if using SSH tunnel)

## Sealed Secrets

- [ ] Sealed-secrets controller deployed
- [ ] Private key backed up securely (see {doc}`/how-to/backup-restore`)
- [ ] All sensitive values stored as SealedSecrets (not plain Secrets in Git)

## Authentication

- [ ] `admin-auth` secret created for Grafana/basic-auth services
- [ ] oauth2-proxy deployed with GitHub OAuth credentials
- [ ] Dex (GitHub) login enabled on Grafana; Headlamp and Alertmanager gated by oauth2-proxy
- [ ] ArgoCD GitHub (Dex) login works for `admin_emails`

## Resource limits

- [ ] All services have CPU/memory requests and limits set
- [ ] ingress-nginx has resource requests

## Storage

- [ ] Every static PV in `additions/local-storage/` is `Bound` to its pod
- [ ] `k8s_data_dirs` role has run on every node (directories exist under `/home/k8s-data/*` on nuc2 and `/var/lib/k8s-data/*` on RK1 nodes)
- [ ] NAS NFS share is mounted by the `k8s-cluster-nfs` PVC in the `backups` namespace
- [ ] At least one backup CronJob run has produced a file on the NAS under `/bigdisk/k8s-cluster/backups/`

## Monitoring

- [ ] kube-prometheus-stack deployed (Prometheus + Grafana + Alertmanager)
- [ ] Grafana accessible and showing dashboards
- [ ] Alert rules reviewed and customised

## Security

- [ ] All container images pinned to specific versions
- [ ] Security contexts applied to all custom deployments
- [ ] Headlamp RBAC reviewed (per-user bindings: admin → cluster-admin, viewer → view)
- [ ] ArgoCD project `sourceRepos` restricted to known repositories
- [ ] No plaintext secrets in Ansible output or Git

## GitOps

- [ ] ArgoCD deployed and tracking the correct Git branch
- [ ] All applications showing `Synced` and `Healthy`
- [ ] Renovate bot configured for automated dependency updates
- [ ] `values.yaml` `repo_branch` matches the active branch

## Backups

- [ ] CronJob backup targets verified with at least 7 days of retention on NAS
- [ ] Sealed-secrets key exported and stored securely
- [ ] Disaster recovery procedure documented and tested
