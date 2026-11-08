# Services Reference

All services deployed by ArgoCD, with their chart sources, versions, and access
methods. If you are trying to decide *what to install*, start with
**Quick-start configurations** below. If you already know what you want, skip
down to the **Service catalogue** for the reference table and per-service
details.

## Quick-start configurations

Not every cluster needs every service. This section helps you pick a
configuration based on what you actually want to run. Services can be
individually enabled or disabled — see {doc}`/how-to/add-remove-services`.

### Baseline (always installed)

All configurations below assume the baseline plumbing that makes ingress,
TLS, and human login work:

- **cert-manager** — Let's Encrypt TLS via Cloudflare DNS-01
- **ingress-nginx** — HTTP(S) ingress controller
- **oauth2-proxy** — GitHub OAuth gate for services without native OIDC
- **Sealed Secrets** — encrypted secrets committed to Git
- **cloudflared** — outbound Cloudflare tunnel (external access without opening ports)

**Baseline prerequisites:**

- A Cloudflare-managed domain (set via `cluster_domain` in `group_vars/all.yml`)
- A Cloudflare API token with DNS edit + Tunnel permissions
- **Two** GitHub OAuth Apps for human logins — one for Dex (OIDC services)
  and one for oauth2-proxy (services without native OIDC)

See {doc}`/how-to/oauth-setup` and {doc}`/how-to/cloudflare-tunnel` for the
setup steps.

### Monitoring-only — dashboards and alerts

Metrics, dashboards, and Slack/email alerting for the cluster and any
workloads you add. Useful as a standalone observability cluster.

**Install:** kube-prometheus-stack (Grafana + Prometheus + Alertmanager).

**Hardware prerequisites:**

- One x86 node for Prometheus and Grafana (both pinned to `node04`); they
  can be split across two nodes

**Storage prerequisites:**

- `/var/lib/k8s-data/prometheus` on the Prometheus host (40Gi)
- `/var/lib/k8s-data/grafana` on the Grafana host (30Gi)

**Other prerequisites:**

- Optional: a Slack webhook for Alertmanager notifications
  (see {doc}`/how-to/monitoring`)

### Minecraft — game servers from world backups

An admin dashboard that launches Minecraft Java servers from a read-only
archive of world backups, with snapshots, restore, and per-world whitelists.

**Install:** Minecraft dashboard (`enable_minecraft: true`), plus either
the VPS relay (`enable_vps_relay: true`).

**Hardware prerequisites:**

- One node to host every world (pinned to `nuc2` by default). Each world
  defaults to 4Gi of memory, so size the node for the worlds you run at once.

**Storage prerequisites:**

- The NFS CSI storage class `nfs-stable` for per-world data, and its share
  root on the NAS
- `minecraft-archive/` (read-only) and `k8s-cluster/minecraft/` on the NAS —
  see {doc}`/how-to/nas-setup`

**Other prerequisites:**

- A VPS on your tailnet running frps (see {doc}`/how-to/vps-relay` and
  {doc}`/how-to/minecraft`)

### Full stack — everything

Install every service in the catalogue below. Use this if you have the
hardware and want the full experience out of the box.

**Minimum hardware:**

- An x86 node for Prometheus and Grafana pinning (`node04`)
- A NAS with an NFS export for backups

**Other prerequisites:**

- Everything listed under the baseline and the individual configurations above

## Service catalogue

| Service | Chart / Source | Version | Namespace | Ingress URL | Auth | Purpose |
|---------|---------------|---------|-----------|-------------|------|---------|
| cert-manager | `jetstack/cert-manager` | v1.20.1 | `cert-manager` | — | — | TLS certificate management |
| cloudflared | Plain manifests | 2026.10.0 | `cloudflared` | — | — | Cloudflare tunnel connector |
| CoreDNS HA | Plain manifests | — | `kube-system` | — | — | Holds K3s's bundled CoreDNS at 2 replicas |
| echo | Plain manifests | 0.9.2 | `echo` | `echo.<domain>` | None | HTTP echo test service |
| Grafana + Prometheus | `prometheus-community/kube-prometheus-stack` | 83.0.2 | `monitoring` | `grafana.<domain>` | Dex (OIDC) | Monitoring and dashboards |
| Headlamp | `headlamp/headlamp` | 0.43.0 | `headlamp` | `headlamp.<domain>` | OAuth + Token | Kubernetes dashboard (with Argo CD plugin) |
| ingress-nginx | `ingress-nginx/ingress-nginx` | 4.15.1 | `ingress-nginx` | — | — | Ingress controller |
| Intel GPU device plugin | Upstream release manifests (vendored) | v0.37.1 | `intel-gpu-plugin` | — | — | Advertises `gpu.intel.com/i915` on Intel iGPU nodes |
| kernel-settings | Inline DaemonSet | — | `kube-system` | — | — | Sysctl tuning for performance |
| Jellyfin | `jellyfin/jellyfin` | 3.6.0 (image 12.3) | `jellyfin` | — (LAN and Tailscale) | Jellyfin users | Media server with Intel GPU transcoding (optional) |
| kured | `kubereboot/kured` | 6.1.0 | `kured` | — | — | Reboots nodes after OS updates, one at a time |
| Minecraft dashboard | `ghcr.io/gilesknap/charts/minecraft-dashboard` (OCI) | 0.2.0 | `minecraft` | `minecraft.<domain>` | OAuth | Launch and manage Minecraft worlds (optional) |
| oauth2-proxy | `oauth2-proxy/oauth2-proxy` | 10.4.2 | `oauth2-proxy` | `oauth2.<domain>` | GitHub | OAuth proxy for Headlamp, Alertmanager and the Minecraft dashboard |
| ntfy | Local chart (`binwiederhier/ntfy`) | v2.34.0 | `ntfy` | `ntfy.<domain>` | ntfy access tokens (no Cloudflare Access) | Push notifications to phones; alerts from the cluster and outside hosts |
| NVIDIA device plugin | `nvidia/nvidia-device-plugin` | 0.19.0 | `nvidia-device-plugin` | — | — | Advertises `nvidia.com/gpu` resources to the scheduler |
| scrap | Helm chart from `github.com/gilesknap/scrap` | 0.2.0 | `scrap` | `scrap.<domain>` | Cloudflare Access + oauth2-proxy | Personal knowledge store (PWA; `/mcp` behind a bearer token) |
| VPS relay | Plain manifests (tailscale v1.102.5, frpc v0.71.0) | — | `vps-relay` | — | Tailscale + frp | Publishes chosen TCP/UDP ports on a VPS's public IP (optional) |
| Sealed Secrets | `bitnami-labs/sealed-secrets` | 2.18.4 | `kube-system` | — | — | Encrypted secrets in Git |
| system-upgrade-controller | Upstream release manifests | v0.20.2 | `system-upgrade` | — | — | Applies k3s patch releases |

## Service details

### cert-manager

Manages TLS certificates via Let's Encrypt. Uses DNS-01 validation through the
Cloudflare API. Includes a `ClusterIssuer` (`letsencrypt-prod`) and a SealedSecret
for the Cloudflare API token. Resource limits: 50m/128Mi request, 200m/256Mi limit.

**Additional manifests:** `additions/cert-manager/templates/`
- `cloudflare-api-token-secret.yaml` — SealedSecret for DNS API token
- `issuer-letsencrypt-prod.yaml` — ClusterIssuer for production Let's Encrypt (uses `domain_email` for ACME notifications)

### cloudflared

Outbound Cloudflare tunnel connector. Runs 2 replicas on different nodes
(required pod anti-affinity) with a PodDisruptionBudget of `maxUnavailable: 1`.
Reads the tunnel token from a SealedSecret. Non-root, read-only rootfs.

**Additional manifests:** `additions/cloudflared/`
- `deployment.yaml` — 2-replica Deployment with hardened security context, and
  its PodDisruptionBudget
- `tunnel-secret.yaml` — SealedSecret for tunnel token

### echo

Simple HTTP echo service ([ealen/echo-server](https://github.com/Ealenn/Echo-Server))
for testing ingress, TLS, and headers. Exposed publicly via Cloudflare tunnel with
`ssl-redirect: false`. Runs as non-root (65534) with read-only root filesystem.
Image pinned to `0.9.2`.

**Additional manifests:** `additions/echo/`
- `manifests.yaml` — Deployment, Service, and Ingress

### Grafana + Prometheus (kube-prometheus-stack)

Full monitoring stack: Prometheus for metrics collection, Grafana for dashboards,
Alertmanager for alerts. Grafana authenticates via Dex (OIDC) with GitHub —
emails in `admin_emails` get Admin role, all other authenticated users get Viewer. Uses
static `local-nvme` PVs pinned by node affinity (Grafana → node04 30Gi,
Prometheus → node04 40Gi). Grafana resource limits: 100m/256Mi request,
500m/512Mi limit. Alertmanager, the Prometheus operator and kube-state-metrics
do not tolerate the workstation taint, so they stay off workstation nodes;
node-exporter runs on every node.

Uses `ServerSideApply=true` sync option due to large CRDs.

### Headlamp

Modern Kubernetes dashboard. Protected by the cluster-wide oauth2-proxy
(admin-only, same as Alertmanager). After OAuth login,
paste a ServiceAccount token generated with
`kubectl create token headlamp -n headlamp` to access the Kubernetes API.
The Helm chart creates a ClusterRoleBinding granting `cluster-admin` to
the default ServiceAccount. Resource limits: 50m/128Mi request,
200m/256Mi limit.

**Argo CD plugin.** The
[Argo CD plugin](https://github.com/headlamp-k8s/plugins/tree/main/argocd)
from the Headlamp project adds an Argo CD sidebar section listing
Applications with their project, source repo, revision, sync status and
health, plus buttons to sync or refresh an Application. It drives the
Kubernetes API rather than the Argo CD REST API, so it needs no Argo CD
credentials — read and patch rights on `applications.argoproj.io` are
enough, which the chart's `cluster-admin` ClusterRoleBinding already
covers. No extra RBAC manifests are required.

The plugin is not on ArtifactHub yet, so the chart's `pluginsManager`
sidecar (which only accepts ArtifactHub URLs) cannot install it. Instead
`templates/dashboard.yaml` sets `config.pluginsDir` and adds an
initContainer that downloads the GitHub release tarball, verifies its
SHA-256, and unpacks it into an emptyDir shared with the Headlamp
container. Set `headlamp.argocd_plugin.enabled` to `false` in
`kubernetes-services/values.yaml` to drop the plugin; bump
`version` and `sha256` together to upgrade it.

### ingress-nginx

NGINX ingress controller. Runs 2 replicas spread across nodes with a
PodDisruptionBudget of `maxUnavailable: 1`. Admission webhooks are disabled.
Resource limits: 100m/256Mi request, 500m/512Mi limit.

### CoreDNS HA

Adds a HorizontalPodAutoscaler fixed at 2 replicas and a PodDisruptionBudget
to the CoreDNS Deployment that K3s manages. See {doc}`/explanations/upgrade-model`.

### kernel-settings

DaemonSet that applies system tuning on all nodes:
- Sets `rmem_max` and `wmem_max` to 7500000 (network buffers)

All busybox images pinned to `1.37`.

### kured

DaemonSet that reboots a node when `/var/run/reboot-required` exists, inside
the nightly reboot window, one node at a time, after draining it. Runs on the
control plane but not on workstation nodes. Exposes `kured_*` metrics to
Prometheus. See {doc}`/explanations/upgrade-model`.

### Jellyfin

Optional (`enable_jellyfin`). The upstream
[jellyfin/jellyfin](https://github.com/jellyfin/jellyfin-helm) chart, pinned
to one node: `/config` is a static `local-nvme` PV there
(`local_storage.jellyfin`), and the pod requests that node's Intel iGPU
(`gpu.intel.com/i915: 1`, see [Intel GPU device plugin](#intel-gpu-device-plugin))
with the node's `render` and `video` groups in `supplementalGroups`. It runs as
a fixed uid/gid (`jellyfin.uid`/`gid`). The media library is a static
read-only NFS PV, mounted at the path a host install used. No Ingress and no
Cloudflare route: LAN and Tailscale only, with `hostNetwork` (off in a trial,
`jellyfin.host_network`). No PodDisruptionBudget, so kured can drain the node.

See {doc}`/how-to/jellyfin`.

### Minecraft dashboard

Optional (`enable_minecraft`). Deployed from the OCI chart published by
[gilesknap/k3s-minecraft](https://github.com/gilesknap/k3s-minecraft), which
creates the dashboard Deployment, Service, a namespace-scoped
ServiceAccount/Role, and three static NFS volumes: the world archive
(mounted read-only), the writable store, and the `nfs-stable` share (mounted
read-only, to check world folders and archives). The dashboard itself installs
one [itzg Minecraft](https://github.com/itzg/minecraft-server-charts)
Helm release per world in the `minecraft` namespace, each with a dynamic
`nfs-stable` PVC and a NodePort from `30565`–`30584`, pinned to one node.
Protected by oauth2-proxy (admin-only, same as Headlamp).

See {doc}`/how-to/minecraft` for setup.

### scrap

Personal knowledge store ([gilesknap/scrap](https://github.com/gilesknap/scrap)).
The Argo CD Application deploys the chart from a git tag into the `scrap`
namespace in its Litestream mode, so it runs on any node. The database is on
the pod's emptyDir, replicated to a static NFS data volume, and the backups
are on a second static NFS volume. There is also a nightly copy of the newest
backup to a `local-nvme` PV, a NetworkPolicy admitting only `ingress-nginx`,
and Claude ingest enabled. The PWA is protected by
Cloudflare Access plus oauth2-proxy. A separate `/mcp` Ingress (`mcp_ingress_enabled: true`)
bypasses oauth2-proxy and is protected by a Cloudflare Access service token
plus scrap's own bearer token (`SCRAP_MCP_TOKEN`, from `scrap-secrets`).

**Additional manifests:** `additions/scrap/`
- `templates/mcp-ingress.yaml` — `/mcp`-only Ingress without oauth2-proxy
- `templates/nfs-volumes.yaml` — static NFS PVs and PVCs for data and backups
- `templates/backup-copy.yaml` — the nightly off-NAS backup copy
- `templates/legacy-pvc.yaml`, `templates/migrate-job.yaml` — the pre-Litestream
  claims, kept as a frozen copy, and the one-off move to NFS
- `templates/scrap-secret.yaml` — SealedSecret `scrap-secrets` holding the
  Claude API key (created by you; not shipped)

See {doc}`/how-to/scrap` for setup.

### VPS relay

Optional (`enable_vps_relay`). One Deployment with two containers: a
Tailscale userspace sidecar that joins the tailnet as an ephemeral node
tagged `tag:vps-relay` and offers SOCKS5 on `127.0.0.1:1055`, and frpc,
which dials frps on the VPS through it. Every entry in `vps_relay.forwards`
becomes one frp proxy per port, so frps publishes those ports on the VPS and
relays each connection to the same port on the entry's `target`. All
connections are outbound from the cluster. Both containers run non-root
with a read-only root filesystem and no service-account token.

**Additional manifests:** `additions/vps-relay/`
- `templates/deployment.yaml` and `templates/frpc-configmap.yaml` — the pod
  and its generated `frpc.toml`
- `templates/vps-relay-secret.yaml` — SealedSecret for the Tailscale OAuth
  client secret and the frp token (created by you; not shipped)

See {doc}`/how-to/vps-relay` for setup, including the frps runbook for the
VPS.

### oauth2-proxy

Lightweight OAuth authentication proxy. Redirects unauthenticated users to GitHub
for login. Protects services without native OIDC support: Headlamp,
Alertmanager and the Minecraft dashboard. Integrated with nginx ingress annotations.
Runs 2 replicas spread across nodes with a PodDisruptionBudget of
`maxUnavailable: 1`; sessions live in the encrypted cookie, so replicas share no
state. Resource limits: 10m/64Mi request, 100m/128Mi limit.

**Additional manifests:** `additions/oauth2-proxy/`
- `oauth2-proxy-secret.yaml` — SealedSecret for GitHub OAuth credentials

See {doc}`/how-to/oauth-setup` for configuration details.

### ntfy

Push-notification server ([ntfy](https://ntfy.sh)), locked down:
`auth-default-access: deny-all`, no sign-up, no login, no web app and no
attachments. Users, tokens and access are declarative: the users and tokens
come from the `ntfy-auth` SealedSecret, the access list from the chart's
values, so no `ntfy user add` is ever run. One write-only user per sender
(`alertmanager` on `cluster-alerts`, `vps` on `vps-alerts`) and a
read-only `phone` user; no admin user. A daily cap of 500 messages per
visitor. One replica with its SQLite user database and
message cache (12h) on an `emptyDir`, so it is not pinned to a node. A
NetworkPolicy admits only `ingress-nginx`. Non-root (10001) with a
read-only root filesystem; probes on `/v1/health`. Resource limits:
10m/32Mi request, 500m/256Mi limit. Public through the Cloudflare tunnel
with a Cloudflare Access **Bypass** application, as the phone app cannot
log in to Access.

**Additional manifests:** `additions/ntfy/`
- `templates/deployment.yaml`, `templates/service.yaml`,
  `templates/configmap.yaml` (`server.yml`), `templates/networkpolicy.yaml`
- `templates/ntfy-auth-secret.yaml` — SealedSecret with the users and
  tokens (`just seal-ntfy`)

See {doc}`/how-to/ntfy` for setup.

### NVIDIA device plugin

DaemonSet that detects NVIDIA GPUs and advertises `nvidia.com/gpu` resources to the
Kubernetes scheduler. Schedules on nodes with label `nvidia.com/gpu.present=true`
(applied by the `k3s` Ansible role for `nvidia_gpu_node` hosts). Once running, it
also sets the `nvidia.com/gpu.present` label and the `nvidia.com/gpu` allocatable
resource on the node.

Requires the NVIDIA container runtime to be configured in k3s's containerd. The
`update_packages` role writes a `config.toml.tmpl` that sets the NVIDIA runtime as
default and survives k3s-agent restarts.

### Intel GPU device plugin

DaemonSet from
[intel-device-plugins-for-kubernetes](https://github.com/intel/intel-device-plugins-for-kubernetes)
that advertises an Intel iGPU (for example Iris Xe) as the `gpu.intel.com/i915`
resource, so a pod gets `/dev/dri` for VAAPI or Quick Sync through a resource
request instead of running privileged. Schedules on nodes with label
`intel.feature.node.kubernetes.io/gpu=true`, applied by the `k3s` Ansible role
for `intel_gpu_node` hosts. That is the label Node Feature Discovery would set,
so NFD can replace the inventory flag later without changing the plugin.

It is the upstream release's plain DaemonSet, vendored in
`additions/intel-gpu-plugin/upstream/` so that a sync never fetches from GitHub,
with a kustomize patch for the node selector and `-shared-dev-num`. It needs
neither the Intel operator nor cert-manager. `-shared-dev-num` sets how many pods
may share each GPU; it starts at 1, so raise it before running a second GPU pod.
Like any DaemonSet pod it is not evicted when kured drains the node, and it has
no PodDisruptionBudget, so it never blocks a reboot.

The i915 kernel driver ships with Ubuntu, so the node needs no extra packages.

**Requesting the GPU:**

```yaml
resources:
  limits:
    gpu.intel.com/i915: 1
```

The plugin mounts the node's `/dev/dri/card*` and `/dev/dri/renderD*` into the
container with their host ownership, `root:render` mode `0660`. A container that
runs as root can use them as they are. A non-root container also needs the
node's `render` group ID in `supplementalGroups`. Look it up on the node with
`getent group render`: it differs between distributions and can change across
an OS release upgrade.

```yaml
securityContext:
  supplementalGroups: [993] # the node's render GID
```

**Verifying:** check the node advertises the resource, then run a test pod
that lists the devices and queries VAAPI with the `vainfo` bundled in the
Jellyfin image:

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,I915:.status.allocatable.gpu\.intel\.com/i915'
kubectl run vainfo --rm -it --restart=Never --image=jellyfin/jellyfin:10.10.7 \
  --overrides='{"spec":{"containers":[{"name":"vainfo","image":"jellyfin/jellyfin:10.10.7",
    "command":["sh","-c","ls -l /dev/dri && /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128"],
    "resources":{"limits":{"gpu.intel.com/i915":"1"}}}]}}'
```

`vainfo` should list the iHD driver and its `VAProfile...` entrypoints. If the
render node has another number, use the one `ls` printed.

### system-upgrade-controller

Rancher's controller plus two Plans (`additions/k3s-upgrade-plans/`) that keep
the nodes on the newest k3s patch of `k3s.minor`, in the nightly upgrade
window. Workstation nodes are excluded. See {doc}`/how-to/upgrade-k3s`.

### Sealed Secrets

Bitnami Sealed Secrets controller. Installed in `kube-system` namespace. Decrypts
`SealedSecret` resources into regular Kubernetes Secrets.

## ArgoCD itself

ArgoCD is not in the `kubernetes-services/templates/` directory — it is installed
directly by the Ansible `cluster` role using the OCI Helm chart (v9.4.17). It is the
foundation that all other services depend on.

Login via Dex (GitHub). The built-in admin account is disabled. RBAC maps
emails to `role:admin` or `role:readonly` via `argocd-rbac-cm.yml`.

Access: `argocd.<domain>` (via Cloudflare tunnel) or `kubectl port-forward svc/argocd-server -n argo-cd 8080:8080`.

See {doc}`/explanations/authentication` for details on how Dex is shared
across services.
