# Services reference

Everything ArgoCD runs on the cluster, plus ArgoCD itself: where each service
comes from, which version is pinned, how it is reached and who may use it.
The live cluster has 25 Applications: the root `all-cluster-services` and the
24 children it renders from `kubernetes-services/templates/`. Versions here
are the pins in those templates and in `kubernetes-services/values.yaml`;
when this page and the code disagree, the code is right.

## Service catalogue

Placement says where the pods run today and what decides it. "Any worker"
means node03, node04, nuc1 or nuc2: node02 is tainted `NoSchedule` for the
control plane and ws03 `workstation=true:NoSchedule`, so only pods that
tolerate those taints land there. node03, the warm-standby control plane,
carries a `PreferNoSchedule` taint: the scheduler uses it when a spread or
anti-affinity rule asks for a second node, and otherwise prefers the others.

### Platform

| Application | Source | Version | Namespace | Replicas and placement |
|-------------|--------|---------|-----------|------------------------|
| `all-cluster-services` | This repository, `kubernetes-services/` (the root app, created by Ansible) | branch `main` | `argo-cd` | Renders the Applications below |
| `sealed-secrets` | `bitnami-labs/sealed-secrets` chart | 2.22.0 | `kube-system` | 1, any worker |
| `cert-manager` | `jetstack/cert-manager` chart | v1.21.3 | `cert-manager` | 1 each of controller, cainjector and webhook, any worker |
| `ingress` | `kubernetes/ingress-nginx` chart | 4.15.1 | `ingress-nginx` | 2, on different nodes, with a PodDisruptionBudget. K3s ServiceLB publishes its ports 80 and 443 on node03, node04, nuc1 and nuc2 |
| `oauth2-proxy` | `oauth2-proxy/oauth2-proxy` chart | 10.7.4 | `oauth2-proxy` | 2, on different nodes, with a PodDisruptionBudget |
| `cloudflared` | Plain manifests, image `cloudflare/cloudflared` | 2026.10.7 | `cloudflared` | 2, required on different nodes, with a PodDisruptionBudget |
| `coredns` | Plain manifests (an HPA and a PodDisruptionBudget for the CoreDNS that K3s bundles) | n/a | `kube-system` | Holds CoreDNS at 2, on different workers |
| `local-storage` | Local chart | n/a | cluster-scoped | The `local-nvme` StorageClass and the static PVs on node04 and nuc2 |
| `nfs-csi` | `kubernetes-csi/csi-driver-nfs` chart | 4.13.4 | `nfs-csi` | Controller 1 (on node02 today), node DaemonSet on all six nodes |
| `kernel-settings` | Plain manifests, `busybox:1.38` | n/a | `kube-system` | DaemonSet `sysctl-tuning` on node03, node04, nuc1 and nuc2 |
| `kured` | `kubereboot/kured` chart | 6.1.0 | `kured` | DaemonSet on every node but ws03 |
| `system-upgrade` | Vendored upstream manifests plus two Plans | controller v0.20.2 | `system-upgrade` | 1 (on node02 today) |
| `intel-gpu-plugin` | Vendored upstream DaemonSet, kustomize patch | 0.37.1 | `intel-gpu-plugin` | DaemonSet on nuc2 only |
| `nvidia-device-plugin` | `NVIDIA/k8s-device-plugin` chart | 0.20.1 | `nvidia-device-plugin` | DaemonSet on ws03 only |
| `backups` | Local chart | n/a | `backups` | CronJobs only: `grafana-daily`, `grafana-weekly` (node04), `jellyfin-daily`, `jellyfin-weekly` (nuc2), `offsite-backup`, `offsite-backup-b2` (when enabled) |

### Operations UIs and monitoring

| Application | Source | Version | Namespace | Replicas and placement |
|-------------|--------|---------|-----------|------------------------|
| `grafana-prometheus` | `prometheus-community/kube-prometheus-stack` chart | 93.3.0 (operator images pinned to v0.94.2) | `monitoring` | Prometheus and Grafana on node04 (local PVs); Alertmanager, operator, kube-state-metrics on any worker; node-exporter on all six nodes |
| `headlamp` | `kubernetes-sigs/headlamp` chart | 0.46.0, Argo CD plugin 0.1.0-alpha | `headlamp` | 1, any worker |
| `argocd-monitor` | OCI chart `ghcr.io/epics-containers/charts/argocd-monitor` | 1.2.0 | `argocd-monitor` | 1, amd64 nodes only (nuc1 or nuc2) |
| `home` | Local chart, image `nginxinc/nginx-unprivileged:1.31-alpine` | n/a | `home` | 1, any worker |
| `echo` | Plain manifests, image `ealen/echo-server` | 0.9.2 | `echo` | 1, any worker |
| `ntfy` | Local chart, image `binwiederhier/ntfy` | v2.34.0 | `ntfy` | 1, any worker (state on an `emptyDir`) |

### Applications

| Application | Source | Version | Namespace | Replicas and placement | Toggle |
|-------------|--------|---------|-----------|------------------------|--------|
| `scrap` | OCI chart `ghcr.io/gilesknap/charts/scrap` | 1.9.2 | `scrap`, `scrap-public` | 1 each, any worker (Litestream on NFS) | none |
| `jellyfin` | `jellyfin/jellyfin` chart | chart 3.7.0, image 12.4 (`12.4.20261026-211555`) | `jellyfin` | 1, nuc2 (local PV and Iris Xe) | `enable_jellyfin` |
| `minecraft` | OCI chart `ghcr.io/gilesknap/charts/minecraft-dashboard` | 0.5.2 | `minecraft` | Dashboard 1, any worker; every world on nuc2 | `enable_minecraft` |
| `vps-relay` | Local chart, images `tailscale/tailscale` and `fatedier/frpc` | v1.102.5, v0.71.0 | `vps-relay` | 1, any worker | `enable_vps_relay` |

Two more switches in `values.yaml` change the set. `enable_kyverno` is `false`:
`templates/kyverno.yaml` (chart 3.9.1) is not rendered, because the app never
settled to Synced and no policies were in use. `enable_oauth2_proxy` and
`enable_cloudflare_tunnel` are both `true`; they do not remove an Application,
they switch the oauth2-proxy annotations on Headlamp's Ingress and the
`ssl-redirect` annotation on every tunnelled Ingress.
{doc}`/how-to/add-remove-services` describes adding and removing Applications.

## Access

Every `gkcluster.org` hostname below is a route on the Cloudflare Tunnel to
ingress-nginx (`tunnel_services` in `cloudflare/locals.tf`), so a request
passes Cloudflare Access at the edge, then whatever the service does itself.
{doc}`/explanations/architecture/authentication` explains the layers and
{doc}`/tutorials/tour` walks through the UIs.

| URL | Service | Cloudflare Access | In the cluster |
|-----|---------|-------------------|----------------|
| <https://home.gkcluster.org> | Landing page with links to everything | Owner | None |
| <https://argocd.gkcluster.org> | ArgoCD | Owner and viewers (`Demo` app) | GitHub through Dex: `admin_emails` are `role:admin`, anyone else `role:readonly` |
| <https://argocd-monitor.gkcluster.org> | argocd-monitor | Owner and viewers | Its own oauth2-proxy sidecar against Dex; inherits the ArgoCD role |
| <https://grafana.gkcluster.org> | Grafana | Owner and viewers | GitHub through Dex: `admin_emails` are Admin, anyone else Viewer |
| <https://alertmanager.gkcluster.org> | Alertmanager | Owner | oauth2-proxy (`admin_emails`) |
| <https://headlamp.gkcluster.org> | Headlamp | Owner | oauth2-proxy (`admin_emails`), then a ServiceAccount token |
| <https://minecraft.gkcluster.org> | Minecraft dashboard | Owner | oauth2-proxy (`admin_emails`) |
| <https://scrap.gkcluster.org> | scrap | Owner; `/mcp` needs the `mcp-access` service token instead | oauth2-proxy (`admin_emails`); `/mcp` needs scrap's bearer token instead |
| <https://pages.gkcluster.org> | scrap's public pages | Bypass (public, cached) | None |
| <https://ntfy.gkcluster.org> | ntfy | Bypass (public, rate-limited) | ntfy access tokens |
| <https://echo.gkcluster.org> | Echo test service | Owner | None |
| <https://oauth2.gkcluster.org> | oauth2-proxy's sign-in and callback endpoints | Owner | n/a |

Not on the tunnel:

| Name | What |
|------|------|
| `home-lan.gkcluster.org`, `home-tailnet.gkcluster.org` | DNS-only records pointing at the LAN and the tailnet address of an ingress node. They serve the same landing page; its JavaScript fetches `/healthz` on each to show whether the browser is on the LAN or the tailnet |
| `mc.gkcluster.org:<port>` | DNS-only record for the VPS; Minecraft players connect here ({doc}`/how-to/minecraft`) |
| `http://192.168.1.92:8096` | Jellyfin, on nuc2's own network: LAN and tailnet only, Jellyfin's own users ({doc}`/how-to/jellyfin`) |
| `https://k3s.lan:6443` | The Kubernetes API (a router DNS record for node02), for `kubectl` |

### Port-forward fallbacks

When Cloudflare, the tunnel or the ingress is down, `kubectl port-forward`
from the devcontainer still reaches each service. It skips Cloudflare Access
and oauth2-proxy, so it relies on the kubeconfig alone.

| Service | Command | Then open |
|---------|---------|-----------|
| ArgoCD | `argo.sh`, or `kubectl -n argo-cd port-forward svc/argocd-server 8080:80` | <http://localhost:8080> |
| Grafana | `grafana.sh`, or `kubectl -n monitoring port-forward sts/grafana-prometheus 3000` | <http://localhost:3000> |
| Headlamp | `dashboard.sh` (also prints a 24 hour token), or `kubectl -n headlamp port-forward svc/headlamp 4466:80` | <http://localhost:4466> |
| Prometheus | `kubectl -n monitoring port-forward svc/grafana-prometheus-kube-pr-prometheus 9090` | <http://localhost:9090> |
| Alertmanager | `kubectl -n monitoring port-forward svc/grafana-prometheus-kube-pr-alertmanager 9093` | <http://localhost:9093> |
| Minecraft dashboard | `kubectl -n minecraft port-forward svc/minecraft-dashboard 8080:80` | <http://localhost:8080> |

`argo.sh`, `grafana.sh` and `dashboard.sh` are written by the `tools` Ansible
role. ArgoCD and Grafana still ask for the GitHub login through Dex, whose
redirects go to the public hostnames, so with the edge down the practical
tools are `kubectl` and Headlamp with a token:

```bash
just headlamp-token      # a 100 day ServiceAccount token
```

## ArgoCD itself

ArgoCD is not in `kubernetes-services/templates/`. The `cluster` Ansible role
installs it with Helm from `oci://ghcr.io/argoproj/argo-helm/argo-cd`, chart
**9.4.17** (ArgoCD v3.3.6), into the `argo-cd` namespace
(`roles/cluster/tasks/argocd.yml`), then applies the AppProject
`kubernetes` and the root Application from `argo-cd/`. One replica of each
component, on any worker.

- **Login:** GitHub through its bundled Dex. The built-in admin account is
  disabled (`admin.enabled: "false"`).
- **RBAC:** `configs.rbac` maps each of `admin_emails` to `role:admin`;
  `policy.default` is `role:readonly`.
- **Dex clients:** `argo-cd`, `argocd-monitor` and `grafana`, so Grafana and
  argocd-monitor log in through the same Dex.
- **AppProject:** `sourceRepos` is an allow-list of this repository and the
  chart registries in the tables above (`argo-cd/argo-project.yaml`). A new
  chart source must be added there and applied with
  `ansible-playbook pb_all.yml --tags cluster`.

{doc}`/explanations/architecture/gitops` describes the app-of-apps layout.

## Service details

### Sealed Secrets

Bitnami's controller, in `kube-system`. It decrypts each `SealedSecret` in Git
into a Secret. See {doc}`/how-to/manage-sealed-secrets`.

### cert-manager

Issues one wildcard certificate, `*.gkcluster.org` and `gkcluster.org`, from
Let's Encrypt by DNS-01 through the Cloudflare API, into the Secret
`cert-manager/wildcard-tls`. ingress-nginx serves it as its default
certificate, so no Ingress needs its own. Requests 50m/128Mi, limits
200m/256Mi.

**Additional manifests:** `additions/cert-manager/templates/`

- `cloudflare-api-token-secret.yaml`: SealedSecret with the DNS API token
  ({ref}`cf-dns01-token`)
- `issuer-letsencrypt-prod.yaml`: the `letsencrypt-prod` ClusterIssuer
- `wildcard-certificate.yaml`: the wildcard Certificate

Its metrics are scraped by a ServiceMonitor in `additions/grafana/`, and
certificate expiry alerts come from there ({doc}`/how-to/monitoring`).

### ingress-nginx

The only ingress controller. Two replicas with a topology spread across
nodes and `maxUnavailable: 1`, so a reboot or drain keeps one serving. The
admission webhook is disabled: its hook Jobs delete themselves before ArgoCD
records them, which left every sync stuck. Requests 100m/256Mi, limits
500m/512Mi.

Most Ingresses are rendered by the small `additions/ingress/` chart, which the
service templates include as a source with `name`, `service_name`,
`service_port` and `oauth2_proxy`.

### oauth2-proxy

GitHub login gate for the services with no login of their own: Headlamp,
Alertmanager, the Minecraft dashboard and scrap. ingress-nginx asks it about
every request (`auth-url` annotation) and it admits only `admin_emails`. Two
replicas; sessions live in the encrypted cookie on `.gkcluster.org`, so the
replicas share no state. Requests 10m/64Mi, limits 100m/128Mi.

**Additional manifests:** `additions/oauth2-proxy/`

- `oauth2-proxy-secret.yaml`: SealedSecret with the GitHub OAuth credentials
- `error-templates.yaml`: the error page shown to an account that is not allowed

See {doc}`/how-to/oauth-setup`.

### cloudflared

The outbound Cloudflare Tunnel connector. Two replicas on different nodes
(required anti-affinity) with `maxUnavailable: 1`; non-root, read-only root
filesystem. The tunnel, its routes and its DNS records are code in
`cloudflare/`; the pod only needs the tunnel token.

**Additional manifests:** `additions/cloudflared/`

- `deployment.yaml`: the Deployment and its PodDisruptionBudget
- `networkpolicy.yaml`: the pod's NetworkPolicy
- `tunnel-secret.yaml`: SealedSecret with the tunnel token
  (`just cf-seal-tunnel-token`)

See {doc}`/how-to/cloudflare-as-code` and
{doc}`/explanations/architecture/networking`.

### CoreDNS HA

K3s owns the CoreDNS Deployment and re-applies it at every server restart, so
this Application does not replace it. It adds an HPA with `minReplicas` and
`maxReplicas` both 2, which holds the Deployment at two replicas, and a
PodDisruptionBudget. See {doc}`/explanations/upgrade-model`.

### local-storage and nfs-csi

`local-storage` defines the `local-nvme` class and one static, node-pinned PV
per entry of `local_storage` in `values.yaml`: Prometheus and Grafana on
node04, Jellyfin, scrap's backup copy and scrap's frozen copy on nuc2. It also
marks K3s's `local-path` class as not the default.

`nfs-csi` provides the two dynamic classes on the NAS: `nfs-stable` (the
default; one fixed folder per claim under `/k8s-dynamic/stable`, archived on
delete) and `nfs-rwx` (a scratch folder per volume under `/k8s-dynamic`,
deleted with the claim).

See {doc}`/explanations/architecture/storage` and
{doc}`/how-to/nfs-stable-paths`.

### kernel-settings

A DaemonSet that raises `net.core.rmem_max` and `net.core.wmem_max` to
7500000 on the nodes it runs on, for network buffers.

### kured and system-upgrade-controller

The nightly maintenance pair. kured reboots a node when
`/var/run/reboot-required` exists, between 02:30 and 05:00 Europe/London, one
node at a time, after draining it; it runs on node02 but not on ws03, and
skips a node that is running a K3s upgrade Job. system-upgrade-controller
applies K3s patch releases of the `k3s.minor` line (v1.34) between 01:00 and
02:00 through two Plans (`additions/k3s-upgrade-plans/`), which exclude ws03.

The controller's manifests are vendored unchanged from its GitHub release in
`additions/system-upgrade-controller/`, so a sync or rebuild does not depend
on GitHub downloads. To upgrade it, re-download both files and update the
version and sha256 sums as the `kustomization.yaml` header there describes.

See {doc}`/explanations/upgrade-model` and {doc}`/how-to/upgrade-k3s`.

### backups

CronJobs that write to `/bigdisk/k8s-cluster/backups` on the NAS through the
static `k8s-cluster-nfs` volume: Grafana's database daily and weekly (on
node04), Jellyfin's database and config daily and weekly (on nuc2), and
`offsite-backup`, which at 05:30 uploads every backup, age-encrypted, to the
Google Drive folder `home-cluster-offsite`, and, once enabled,
`offsite-backup-b2`, which uploads the NAS backups to a Backblaze B2 bucket
with Object Lock. scrap's backups are CronJobs of
its own chart, and etcd's is a systemd timer on node02. See
{doc}`/how-to/backup-restore`.

### Grafana + Prometheus (kube-prometheus-stack)

Prometheus, Grafana, Alertmanager, the operator, kube-state-metrics and
node-exporter, with this cluster's alert rules and the Alertmanager to ntfy
route. Synced with `ServerSideApply=true` because of the size of its CRDs.
See {doc}`/how-to/monitoring`.

### Headlamp

Kubernetes dashboard behind oauth2-proxy. After the GitHub login, paste a
ServiceAccount token (`just headlamp-token`); the chart binds the `headlamp`
ServiceAccount to `cluster-admin`. Requests 50m/128Mi, limits 200m/256Mi.

The [Argo CD plugin](https://github.com/headlamp-k8s/plugins/tree/main/argocd)
adds a sidebar section listing Applications with sync and health status and
buttons to sync or refresh. It drives the Kubernetes API, not the ArgoCD API,
so it needs no ArgoCD credentials. The plugin is not on ArtifactHub, so
`templates/dashboard.yaml` adds an init container that downloads the release
tarball, verifies its SHA-256 and unpacks it into an `emptyDir`. Bump
`headlamp.argocd_plugin.version` and `sha256` together; set `enabled: false`
to drop it.

### argocd-monitor

A dashboard of Application status from
[epics-containers/argocd-monitor](https://github.com/epics-containers/argocd-monitor),
with links from each workload to its Grafana dashboard. It logs in through
Dex with its own oauth2-proxy sidecar (client `argocd-monitor`, SealedSecret
`argocd-monitor-oauth`) and talks to `argocd-server` inside the cluster.
Pinned to amd64 nodes.

### home

nginx serving a static landing page from a ConfigMap, with a card per web UI
and the LAN and tailnet probes described under Access.

### echo

[ealen/echo-server](https://github.com/Ealenn/Echo-Server): returns the
request it received as JSON, which shows the headers that Cloudflare,
ingress-nginx and oauth2-proxy add. Non-root with a read-only root
filesystem.

### ntfy

Self-hosted push notifications at `ntfy.gkcluster.org`, locked down:
`auth-default-access: deny-all`, no sign-up, no web app, no attachments. Users,
tokens and access are declarative, from the `ntfy-auth` SealedSecret and the
chart's values: write-only senders (`alertmanager` and `scrap` on
`cluster-alerts`, `vps` on `vps-alerts`) and a read-only `phone` user. It is public through the tunnel
with a bypass Access application, because the phone app cannot log in to
Access, and a Cloudflare rate-limiting rule. A NetworkPolicy admits only
ingress-nginx, the Alertmanager pods and the scrap pods. See {doc}`/how-to/ntfy`.

### scrap

Personal knowledge store ([gilesknap/scrap](https://github.com/gilesknap/scrap)).
The pod runs on any node: the database is on an `emptyDir`, replicated by
Litestream to a static NFS volume on the NAS. The web UI is behind Cloudflare
Access and oauth2-proxy; `/mcp` has its own Ingress behind a Cloudflare
service token and scrap's bearer token; public pages are served from the
`scrap-public` namespace at `pages.gkcluster.org`. See {doc}`/how-to/scrap`.

### Jellyfin

The upstream chart, pinned to nuc2 for its config volume (a `local-nvme` PV at
`/home/k8s-data/jellyfin`) and the Iris Xe (see
[Intel GPU device plugin](#intel-gpu-device-plugin)). `hostNetwork`, so it
answers on nuc2's port 8096 on the LAN and the tailnet; no Ingress and no
Cloudflare route. The library is a read-only NFS mount of `/bigdisk/media`.
See {doc}`/how-to/jellyfin`.

### Minecraft dashboard

The OCI chart from
[gilesknap/k3s-minecraft](https://github.com/gilesknap/k3s-minecraft): an
admin UI that installs one
[itzg Minecraft](https://github.com/itzg/minecraft-server-charts) Helm release
per world in its own namespace, each with an `nfs-stable` claim and a NodePort
from 30565 to 30584 on nuc2. Players come in through the VPS relay. See
{doc}`/how-to/minecraft`.

### VPS relay

One pod with two containers: a Tailscale userspace sidecar that joins the
tailnet as an ephemeral node tagged `tag:vps-relay`, and frpc, which dials
frps on the VPS through it. Each entry in `vps_relay.forwards` publishes its
ports on the VPS's public address and relays them to the same ports on its
`target`; today that is the `minecraft` forward, 30565 to 30584 to nuc2. Every
connection is outbound from the cluster. Both containers are non-root with a
read-only root filesystem and no service-account token. See
{doc}`/how-to/vps-relay`.

### NVIDIA device plugin

DaemonSet that advertises ws03's GPU as `nvidia.com/gpu`. It schedules on
nodes labelled `nvidia.com/gpu.present=true`, which the `k3s` Ansible role
sets for hosts with `nvidia_gpu_node: true` in `hosts.yml`, and tolerates the
`workstation` taint. A pod that wants the GPU must tolerate that taint too.

The node needs the NVIDIA container runtime in K3s's containerd: the
`update_packages` role writes a `config.toml.tmpl` that makes it the default
runtime and survives `k3s-agent` restarts.

### Intel GPU device plugin

DaemonSet from
[intel-device-plugins-for-kubernetes](https://github.com/intel/intel-device-plugins-for-kubernetes)
that advertises nuc2's Iris Xe as the `gpu.intel.com/i915` resource, so a pod
gets `/dev/dri` for VAAPI or Quick Sync through a resource request instead of
running privileged. It schedules on nodes labelled
`intel.feature.node.kubernetes.io/gpu=true`, which the `k3s` Ansible role sets
for hosts with `intel_gpu_node: true` in `hosts.yml`. That is the label Node
Feature Discovery would set, so NFD could replace the inventory flag later
without changing the plugin.

It is the upstream release's plain DaemonSet, vendored in
`additions/intel-gpu-plugin/upstream/` so that a sync never fetches from
GitHub, with a kustomize patch for the node selector, a toleration of the
`workstation` taint and `-shared-dev-num`. It needs neither the Intel operator
nor cert-manager. `-shared-dev-num` sets how many pods may share each GPU; it
is 1, and Jellyfin holds that one, so raise it before running a second GPU
pod. Like any DaemonSet pod it is not evicted when kured drains the node, and
it has no PodDisruptionBudget, so it never blocks a reboot.

The i915 kernel driver ships with Ubuntu, so the node needs no extra packages.

**Requesting the GPU:**

```yaml
resources:
  limits:
    gpu.intel.com/i915: 1
```

The plugin mounts the node's `/dev/dri/card*` and `/dev/dri/renderD*` into the
container. On nuc2 the render node is `root:render`, mode `0660`, so a
non-root container carries the node's `render` group ID in
`supplementalGroups`, as Jellyfin does. Look it up on the node with
`getent group render`: it is allocated dynamically and can change across an
OS release upgrade. (In the live Jellyfin pod the device nodes show as owned
by the pod's own uid and gid, so the group is a second line of access there.)

```yaml
securityContext:
  supplementalGroups: [992] # nuc2's render GID
```

**Verifying:** check the node advertises the resource, then query VAAPI from
the Jellyfin pod, which holds the GPU, with the `vainfo` bundled in its image:

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,I915:.status.allocatable.gpu\.intel\.com/i915'
kubectl -n jellyfin exec deploy/jellyfin -- sh -c \
  'ls -l /dev/dri && /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128'
```

`vainfo` lists the iHD driver and its `VAProfile...` entrypoints. If the
render node has another number, use the one `ls` printed.
