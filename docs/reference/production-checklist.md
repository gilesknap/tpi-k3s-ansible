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

- [ ] Tunnel created in Cloudflare dashboard
- [ ] Tunnel token SealedSecret committed to Git
- [ ] cloudflared deployment running (2 replicas)
- [ ] Public hostnames configured for tunnel-exposed services
- [ ] WAF skip rule for SSH hostname (if using SSH tunnel)

## Sealed Secrets

- [ ] Sealed-secrets controller deployed
- [ ] Private key backed up securely (see {doc}`/how-to/backup-restore`)
- [ ] All sensitive values stored as SealedSecrets (not plain Secrets in Git)

## Authentication

- [ ] `admin-auth` secret created for Grafana/basic-auth services
- [ ] oauth2-proxy deployed with GitHub OAuth credentials
- [ ] OAuth enabled on Grafana, Longhorn, Headlamp, Open WebUI
- [ ] ArgoCD admin password retrieved and changed from default

## Resource limits

- [ ] All services have CPU/memory requests and limits set
- [ ] LLM services have appropriate memory limits for loaded models
- [ ] ingress-nginx has resource requests

## Storage

- [ ] Longhorn deployed with 3 replicas per volume
- [ ] VolumeSnapshotClass deployed
- [ ] NFS server configured for LLM model storage (if applicable)
- [ ] Backup target configured in Longhorn (NFS or S3)

## Monitoring

- [ ] kube-prometheus-stack deployed (Prometheus + Grafana + Alertmanager)
- [ ] Grafana accessible and showing dashboards
- [ ] Longhorn ServiceMonitor enabled
- [ ] Alert rules reviewed and customised

## Security

- [ ] All container images pinned to specific versions
- [ ] Security contexts applied to all custom deployments
- [ ] Headlamp RBAC reviewed (currently cluster-admin; scope down when ready)
- [ ] ArgoCD project `sourceRepos` restricted to known repositories
- [ ] No plaintext secrets in Ansible output or Git

## GitOps

- [ ] ArgoCD deployed and tracking the correct Git branch
- [ ] All applications showing `Synced` and `Healthy`
- [ ] Renovate bot configured for automated dependency updates
- [ ] `values.yaml` `repo_branch` matches the active branch

## Backups

- [ ] Longhorn volume snapshots configured (recurring)
- [ ] Sealed-secrets key exported and stored securely
- [ ] Disaster recovery procedure documented and tested
