# Upgrade Model

Nodes patch and reboot themselves overnight, one at a time. Larger changes,
such as a new k3s minor version or an Ubuntu release upgrade, stay
deliberate edits to the repository.

## The nightly cycle

All times are Europe/London and set in `kubernetes-services/values.yaml`
(`k3s.upgrade_window`, `kured`) and the `update_packages` role defaults.

| Time | What | Component |
|------|------|-----------|
| 00:00–00:30 | Install Ubuntu updates, including new kernels | unattended-upgrades |
| 01:00–02:00 | Apply k3s patch releases, control plane first | system-upgrade-controller |
| 02:30–05:00 | Reboot nodes that need it, one at a time | kured |

**OS updates.** The `update_packages` role configures unattended-upgrades on
every non-workstation node to install from both the `-security` and
`-updates` pockets, so kernel updates are included. A package that needs a
reboot writes `/var/run/reboot-required`.

**k3s patches.** [system-upgrade-controller](https://github.com/rancher/system-upgrade-controller)
runs two Plans that follow the k3s release channel for one minor version
(`k3s.minor`, e.g. `v1.34`). The server Plan takes an etcd snapshot, cordons
the control plane and upgrades it. The agent Plan then drains and upgrades
the workers one at a time. A new minor version is never installed on its
own: see {doc}`/how-to/upgrade-k3s`. With a single control plane there is
one etcd member, so a failed server upgrade leaves the API down until it is
fixed or restored from the `pre-upgrade-*` snapshot in
`/var/lib/rancher/k3s/server/db/snapshots`.

**Reboots.** [kured](https://kured.dev/) runs on every node except
workstations. Inside its window it takes a cluster-wide lock, drains the
node, reboots it and uncordons it when it is back, then releases the lock
for the next node. If a drain does not finish within 15 minutes, the node is
uncordoned and retried later instead of being forced.

**No overlap.** kured and system-upgrade-controller each drain nodes and
know nothing about each other, so they get separate windows; keep the gap
if you move either one. system-upgrade-controller only starts a round of
upgrades inside its window, but it finishes a round it has started, node by
node, even after the window closes. A slow round can therefore reach the
kured window, so kured never reboots a node while an upgrade Job runs on it
(its `blockingPodSelector`).

Both drain through the eviction API, so PodDisruptionBudgets are respected
even if they ever drain two nodes at once.

## Running the servers play by hand

`ansible-playbook pb_all.yml --tags servers` dist-upgrades every node in
parallel, but it never reboots a node that is in the cluster (its k3s unit
is installed). It leaves `/var/run/reboot-required` in place and reports
that kured will reboot the node in its next window, so the play is safe to
run at any time.

To reboot such nodes straight away, add `-e reboot_now=true`. A later play
in `pb_all.yml` then takes the nodes that need it one at a time
(`serial: 1`): it drains the node, reboots it, waits until the Node is
Ready with its new boot ID and uncordons it, unless it was already
cordoned before the drain. The drain, wait and uncordon logic is the
`node_reboot` role, which the `rk1_os` conversion shares.

A node without k3s, being provisioned for the first time, is rebooted at
the end of `update_packages` if the dist-upgrade asks for it, so k3s is
installed on the new kernel. It has nothing to drain. Workstations are
never rebooted, even with `reboot_now`; the play warns instead. That includes
a GPU workstation after its first NVIDIA driver install: reboot it by hand
before relying on GPU pods.

## What stays up during a reboot

Shared services run two replicas on different nodes, each with a
PodDisruptionBudget of `maxUnavailable: 1`, so a drain always leaves one
running:

- CoreDNS (see below)
- ingress-nginx controller
- oauth2-proxy
- cloudflared

Workloads pinned to one node by a `local-nvme` volume or a node selector,
for example Prometheus, Grafana, scrap and Minecraft worlds, are down while
their node reboots, typically a few minutes.

Rebooting the control plane takes the Kubernetes API down for a few minutes
while running pods keep serving. Alertmanager, the Prometheus operator and
kube-state-metrics do not tolerate the workstation taint, so they run on
cluster nodes and move with drains like everything else.

### CoreDNS

K3s deploys CoreDNS itself and re-applies its manifest whenever the K3s
server restarts, so edits to the Deployment do not last. That manifest
leaves `replicas` unset, so the `coredns` ArgoCD app adds a
HorizontalPodAutoscaler fixed at two replicas plus a PodDisruptionBudget;
the bundled pod spec already spreads replicas across nodes. It does not
tolerate the control plane's `node-role.kubernetes.io/master` taint, so
replicas are scheduled onto workers and DNS stays up while the control plane
reboots. A replica started on the control plane before the taint was applied
(during bootstrap) moves to a worker at its first drain.

This was chosen over disabling the bundled CoreDNS and installing the Helm
chart: K3s still provides DNS from the first boot, before ArgoCD (which
needs DNS to reach Git) is running, so the rebuild path is unchanged.

## Workstation nodes

Workstation nodes (`workstation: true`) are rebooted and upgraded by their
owner. Neither kured, system-upgrade-controller nor Ansible reboots them, and
unattended-upgrades keeps Ubuntu's default (security-only) policy. Upgrade
K3s on them by hand after a minor upgrade.

## What stays manual

- **k3s minor versions:** edit `k3s.minor`; see {doc}`/how-to/upgrade-k3s`.
- **Ubuntu release upgrades and re-flashing:** Ansible runs.
- **Service versions:** chart and image pins in this repository, applied by
  ArgoCD on merge.
