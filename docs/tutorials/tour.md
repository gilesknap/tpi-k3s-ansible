# A tour of the cluster

A guided walk round the running cluster that takes about twenty minutes. It
is for the owner coming back after a break and for a visitor who wants to
see what is there. Nothing on this page changes the cluster: every command
reads, and the one that creates something (a Headlamp login token) makes a
short-lived credential, not a resource.

A visitor without access can still follow along: the commands and their
output are shown, and each stop links to the page that explains it.

## 1. Open the devcontainer

Everything is run from the repo's devcontainer, which carries Ansible,
`kubectl`, `helm`, `kubeseal`, `argocd`, `tofu` and `just`. On the
workstation, with the ansible key loaded in `ssh-agent`:

```bash
cd tpi-k3s-ansible
code .          # then "Reopen in Container"
```

The container build runs `ansible-playbook pb_all.yml --tags tools`, which
installs the cluster tools into `/root/bin` and fetches the kubeconfig. The
kubeconfig points at `https://k3s.lan:6443`, a name the router resolves to
the control plane (node02 today), so `kubectl` works straight away.
{doc}`/how-to/claude-code` covers the container in more detail.

## 2. One-screen health check

```bash
just status
```

`scripts/status` prints four things: the nodes, the ArgoCD applications,
any pod that is not `Running` or `Completed`, and any certificate that is
not ready. On a healthy cluster only the first two sections appear:

```text
=== Nodes ===
NAME     STATUS   ROLES                AGE     VERSION
node02   Ready    control-plane,etcd   6d13h   v1.34.13+k3s1
node03   Ready    <none>               213d    v1.34.13+k3s1
...
=== ArgoCD Apps ===
all-cluster-services   Synced   Healthy
argocd-monitor         Synced   Healthy
...
```

This is the command to run first whenever something feels wrong.

## 3. Meet the nodes

```bash
kubectl get nodes -o wide
```

Six nodes, all on Ubuntu 26.04 and the same K3s patch release (the
`v1.34` line set by `k3s.minor` in `kubernetes-services/values.yaml`):

| Node | Address | What it is | What it does |
|------|---------|------------|--------------|
| `node02` | 192.168.1.82 | Turing RK1, arm64, 8 GB | The control plane and etcd. Tainted `NoSchedule`, so no workloads |
| `node03` | 192.168.1.83 | Turing RK1, arm64, 8 GB | Warm-standby control plane, tainted `PreferNoSchedule` so it stays light |
| `node04` | 192.168.1.84 | Turing RK1, arm64, 32 GB | Worker. Holds the Prometheus and Grafana `local-nvme` volumes |
| `nuc1` | 192.168.1.91 | NUC, amd64, 12 CPUs, 32 GB | Worker |
| `nuc2` | 192.168.1.92 | NUC, amd64, 8 CPUs, 64 GB, Intel Iris Xe | Worker. Holds Jellyfin, every Minecraft world and scrap's backup copy |
| `ws03` | 192.168.1.10 | Workstation, amd64, NVIDIA GPU | Tainted `workstation=true:NoSchedule`: GPU and monitoring pods only, and never rebooted by automation |

The three RK1s sit on one Turing Pi board whose BMC is `turingpi`
(192.168.1.80). The board's remaining slot (slot 1) holds `node01`, a CM4 and the
former control plane, which is no longer in `hosts.yml` or the cluster.

To see the taints that shape scheduling:

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key'
```

More in {doc}`/explanations/architecture/hardware`.

## 4. See what ArgoCD delivers

```bash
kubectl get applications -n argo-cd
```

There are 28 applications. `all-cluster-services` is the root: it renders
the Helm chart in `kubernetes-services/`, whose templates are the other 27.
Roughly, they fall into four groups:

| Group | Applications |
|-------|--------------|
| Platform | `cilium`, `gateway-api-crds`, `gateway`, `cert-manager`, `cloudflared`, `coredns`, `sealed-secrets`, `oauth2-proxy`, `kernel-settings` |
| Storage and backups | `local-storage`, `nfs-csi`, `backups` |
| Maintenance and devices | `kured`, `system-upgrade`, `intel-gpu-plugin`, `nvidia-device-plugin` |
| Things to look at and use | `home`, `grafana-prometheus`, `headlamp`, `hubble-ui`, `argocd-monitor`, `echo`, `scrap`, `jellyfin`, `minecraft`, `ntfy`, `vps-relay` |

Every one should be `Synced` and `Healthy`. ArgoCD itself is not in the
list: Ansible installs it, and it then delivers everything else. More in
{doc}`/explanations/architecture/gitops`.

## 5. The front door: home.gkcluster.org

Open <https://home.gkcluster.org>. The request goes to Cloudflare, which
asks for a login first (Cloudflare Access: the owner's GitHub login), then
down the Cloudflare Tunnel to Cilium's Gateway in the cluster. Invited viewers
are let through Cloudflare Access only to ArgoCD, Grafana and ArgoCD
Monitor, not to the home page.

The home page is a static page of cards. The badge on a card says which
in-cluster login comes after Cloudflare's:

- **SSO**: the service signs in through Dex (GitHub), running inside
  ArgoCD. One GitHub login covers ArgoCD, Grafana and argocd-monitor.
- **OAuth**: the service sits behind the shared oauth2-proxy, which only
  lets the addresses in `admin_emails` through.
- no badge: no in-cluster login.

Work through the cards one at a time.

### ArgoCD

<https://argocd.gkcluster.org>. Click the single sign-on button (**Log in
via Dex**), which hands over to GitHub; the built-in admin account is
disabled. The owner gets the admin role, anyone else who
got past Cloudflare Access is read-only. Open `all-cluster-services` to see
the tree of child applications, then any child to see its resources and
sync history.

### ArgoCD Monitor

<https://argocd-monitor.gkcluster.org>. A dashboard of application health
over time, signed in through Dex with the same role as in ArgoCD. An
application's detail page links each workload, pod and node to the matching
Grafana dashboard with the namespace already selected.

### Grafana

<https://grafana.gkcluster.org>. Click **Sign in with GitHub (via Dex)**;
the password form is turned off. Addresses in `admin_emails` are Grafana
admins and everyone else is a viewer. The kube-prometheus-stack dashboards
are preloaded: start with *Kubernetes / Compute Resources / Cluster* and
*Node Exporter / Nodes*. See {doc}`/how-to/monitoring`.

### Headlamp

<https://headlamp.gkcluster.org>. After the oauth2-proxy gate, Headlamp
asks for a ServiceAccount token. Print one in the devcontainer and paste it
in:

```bash
just headlamp-token
```

The token lasts 100 days. Headlamp shows pods, logs and every Kubernetes
object, and its Argo CD plugin adds a sidebar section listing the
applications.

### Alertmanager

<https://alertmanager.gkcluster.org>, behind oauth2-proxy. It lists the
alerts that are firing and the silences in force. Alerts are pushed to the
owner's phone through ntfy.

### scrap

<https://scrap.gkcluster.org>, behind oauth2-proxy. scrap is the owner's
personal knowledge store; Claude sessions reach it at `/mcp` with a bearer
token rather than a browser login. See {doc}`/how-to/scrap`.

### Pages

<https://pages.gkcluster.org>. Pages published from scrap. This one is
public on purpose: no Cloudflare Access and no login, and Cloudflare caches
it.

### ntfy

<https://ntfy.gkcluster.org>. The push notification service. It is also
open at the edge, because the phone app cannot do a Cloudflare login, so
ntfy's own access tokens are the gate. See {doc}`/how-to/ntfy`.

### Minecraft

<https://minecraft.gkcluster.org>, behind oauth2-proxy. The dashboard
starts, stops, snapshots and restores Minecraft worlds, all of which run on
nuc2. Players never see this page: they connect a Minecraft client to
`mc.gkcluster.org:<port>`, which is the VPS relay, with the port shown
against each world. See {doc}`/how-to/minecraft` and
{doc}`/how-to/vps-relay`.

### The Network row

The second group of cards, headed **Network**, links to things outside the
cluster. Two of them
(the OpenWrt router at 192.168.1.1, and Jellyfin) are greyed out until the
page finds that the browser is on the LAN or on the tailnet. It finds out
by fetching `home-lan.gkcluster.org` and `home-tailnet.gkcluster.org`, two
DNS-only names that point at a LAN address and a tailnet address of a
worker: whichever answers, the browser can reach that network.

## 6. Two services that are not on the home page

### Jellyfin

Jellyfin has no HTTPRoute and no Cloudflare route. Its pod runs on nuc2's own
network, so it answers on port 8096 of every nuc2 interface:

- on the LAN: <http://192.168.1.92:8096>
- away from home: the same port on nuc2's tailnet address (the Jellyfin
  card on the home page links to it)

Jellyfin has its own user accounts. See {doc}`/how-to/jellyfin`.

### echo

<https://echo.gkcluster.org> returns the request it received as JSON:
method, path, headers. It is the quickest proof that Cloudflare, the
tunnel, the Gateway and a pod all work, and it shows the headers that
Cloudflare and the Gateway's Envoy add on the way in.

## 7. When the front door is shut

If the tunnel, Cloudflare or the Gateway is down, `kubectl` still works
from the devcontainer, and the `tools` role has left three port-forward
scripts in `/root/bin`:

| Script | What it forwards | Open |
|--------|------------------|------|
| `dashboard.sh` | `svc/headlamp` in `headlamp`, and prints a 24 hour token | <http://localhost:4466> |
| `grafana.sh` | `sts/grafana-prometheus` in `monitoring` | <http://localhost:3000> |
| `argo.sh` | `svc/argocd-server` in `argo-cd` | <http://localhost:8080> |

Each one starts `kubectl port-forward` in the background. The devcontainer
shares the workstation's network, so the address opens in the
workstation's browser.

:::{important}
A Dex login does not complete over a localhost port-forward. ArgoCD and
Grafana both send the browser to `https://argocd.gkcluster.org/api/dex/...`
to sign in and expect to be called back at their public hostname, and both
have their password login turned off. So `argo.sh` and `grafana.sh` show
the login page but cannot get past it while the public route is down.
:::

What does work without the front door:

- **Headlamp** through `dashboard.sh`: the port-forward skips oauth2-proxy
  and the token is the only login, so this is the full web UI.
- **ArgoCD without its UI**: `kubectl get applications -n argo-cd`, and
  `kubectl describe application <name> -n argo-cd` for the sync error.
- **Everything else** through `kubectl get`, `describe` and `logs`.

{doc}`/reference/troubleshooting` takes it from there.

## 8. Where it lives in the repo

| To change | Edit |
|-----------|------|
| Which machines are nodes, and their per-node flags | `hosts.yml` |
| The control plane, the standby, the API name, the domain, the branch ArgoCD tracks | `group_vars/all.yml` |
| How a node is installed and joined | `roles/` (`flash`, `move_fs`, `update_packages`, `k3s`, ...) run by `pb_all.yml` |
| Service switches, chart versions, the NAS paths, maintenance windows | `kubernetes-services/values.yaml` |
| One service's ArgoCD application | `kubernetes-services/templates/<service>.yaml` |
| A service's own manifests, SealedSecrets and alert rules | `kubernetes-services/additions/<service>/` |
| ArgoCD itself, its Dex login and RBAC | `roles/cluster/tasks/argocd.yml` and `argo-cd/` |
| Which chart repositories ArgoCD may pull from | `argo-cd/argo-project.yaml` |
| Where a `local-nvme` volume lives | `local_storage` in `values.yaml` and `k8s_data_dirs` in `group_vars/all.yml`, together |
| Public hostnames, DNS, Cloudflare Access, rate limits | `cloudflare/` (`locals.tf` holds the list of hostnames) |
| The cards on the home page | `kubernetes-services/additions/home/templates/manifests.yaml` |
| Backup jobs | `kubernetes-services/additions/backups/` and `roles/etcd_backup/` |
| The day-to-day commands | `justfile` and `scripts/` |
| What Claude Code knows and must not do | `CLAUDE.md`, `.claude/commands/`, `.claude/skills/` |

## Where to go next

To understand how it fits together, read the architecture pages, starting
at {doc}`/explanations/architecture`:

- {doc}`/explanations/architecture/hardware` and
  {doc}`/explanations/architecture/provisioning`: the machines and how
  Ansible installs them
- {doc}`/explanations/architecture/gitops`: how a commit becomes a running
  pod
- {doc}`/explanations/architecture/networking` and
  {doc}`/explanations/architecture/authentication`: the path a request took
  in step 5, and the three logins on it
- {doc}`/explanations/architecture/storage` and
  {doc}`/explanations/architecture/backups`: where data lives and how it
  is protected
- {doc}`/explanations/architecture/claude-code`: how Claude Code is fenced
  in and what it is given

To do something:

- {doc}`/how-to/work-in-branches`: make a change and ship it
- {doc}`/how-to/add-remove-services`: add a service
- {doc}`/how-to/node-operations`: drain, reboot, fence or add a node
- {doc}`/how-to/backup-restore`: check the backups and restore from one
- {doc}`/tutorials/build-the-cluster`: build the whole thing from bare
  metal
