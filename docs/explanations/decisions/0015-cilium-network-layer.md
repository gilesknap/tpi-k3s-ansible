# 15. Cilium Replaces Flannel, kube-proxy and k3s's Policy Controller

**Status:** Accepted

## Context

The cluster ran k3s's built-in network layer: flannel (VXLAN) for the pod network, kube-proxy for
Services, and k3s's embedded kube-router controller for the five NetworkPolicies. ingress-nginx,
the Ingress controller, went end-of-life upstream in March 2026 and gets no more CVE fixes.
Cilium's Gateway API implementation is the planned replacement, and needs Cilium as the CNI.
Cilium also brings DNS-name egress rules, eBPF Services and Hubble's flow visibility, and the
owner is learning it for work.

The owner's decisions are in issue #777. This is phase 1 of 2: the network layer only.
ingress-nginx and its Ingresses are untouched; phase 2 moves them to Gateway API.

## Decision

Cilium 1.20 becomes the CNI, the NetworkPolicy engine and the kube-proxy replacement. k3s's
servicelb stays. The move is done by a cluster rebuild, not node by node.

### What k3s keeps and drops

`roles/k3s/templates/k3s-server-config.yml.j2` sets `flannel-backend: none`,
`disable-network-policy: true` and `disable-kube-proxy: true`, as the Cilium k3s guide says
([Installation using K3s](https://docs.cilium.io/en/v1.20/installation/k3s/)). The k3s docs list
the first two as flags that must match on every server
([k3s server CLI](https://docs.k3s.io/cli/server)). The agents need no change: they read the
flannel backend, the policy-controller switch and the kube-proxy switch from the server when they
start (`pkg/agent/config/config.go` in k3s 1.34). nuc2's `flannel_iface` is dropped from the
inventory, as there is no flannel; its `node_ip` stays, and Cilium uses that address.

With no flannel, k3s leaves containerd's CNI paths at their defaults, `/etc/cni/net.d` and
`/opt/cni/bin` (`pkg/executor/embed/embed.go`), which are the Cilium chart's defaults too.

Changing these settings on a live server would cut every pod off the network with nothing to take
over. `roles/k3s/tasks/control.yml` therefore refuses to apply the new configuration to a server
whose current one still runs flannel (it only warns in `--check`). A fresh install and a server
already on Cilium pass, so re-runs of `--tags k3s` after the rebuild are unaffected.

### Bootstrap, and adoption by ArgoCD

Nodes are NotReady until a CNI runs, and ArgoCD needs pod networking, so ArgoCD cannot be the
first to install Cilium. Two ways were considered:

- **A k3s HelmChart manifest** in `/var/lib/rancher/k3s/server/manifests`. k3s's helm-controller
  would keep reconciling it, and fight ArgoCD over every resource, for as long as the file exists;
  removing the file uninstalls the chart.
- **A Helm install from Ansible**, like the ArgoCD bootstrap in `roles/cluster`. Chosen.

`roles/k3s/tasks/cilium.yml` runs once from the controller, after the nodes have joined and before
the role waits for kube-system pods. If there is no `cilium` DaemonSet, it installs the chart with
`helm install --wait` and then deletes Helm's release record, so nothing suggests a later
`helm upgrade`. If there is one, it does nothing.

There is one copy of the version and values: the ArgoCD Application in
`kubernetes-services/templates/cilium.yaml`. Ansible reads that file's `targetRevision` and
`valuesObject`, as `roles/cluster` already reads the sealed-secrets Application. The file therefore
holds no Helm template expressions. When the root Application syncs, ArgoCD renders the same chart
with the same values and applies it over the resources Ansible made; with annotation tracking (the
default in ArgoCD 3) it adds its tracking annotation and changes nothing else, so the agents do not
restart. From then on ArgoCD owns Cilium: upgrades and value changes go through Git.

Two chart settings keep ArgoCD in sync, following Cilium's
[ArgoCD troubleshooting page](https://docs.cilium.io/en/v1.20/configuration/argocd-issues/):

- `hubble.tls.auto.method: cronJob`. The default, `helm`, generates new certificates on every
  render, so ArgoCD would show the app out of sync for ever. The Job (and a CronJob that renews the
  certificates) writes them into Secrets instead, reusing the `cilium-ca` CA once it exists.
- `CiliumIdentity`, `CiliumEndpoint` and `CiliumEndpointSlice` are already in the argo-cd chart's
  default `resource.exclusions`, so ArgoCD neither shows nor prunes them.

The ServiceMonitors are not the chart's: they are in `additions/grafana`, synced by the
Application that installs their CRD, as `cert-manager-servicemonitor.yaml` already is. The chart's
would fail at bootstrap, when no ServiceMonitor CRD exists yet.

### Kube-proxy replacement

`kubeProxyReplacement: true` with `k8sServiceHost: k3s.lan` and `k8sServicePort: 6443`. Without
kube-proxy, nothing serves the `kubernetes` Service until Cilium runs, so the agents must be told
where the API server itself is
([Kubernetes Without kube-proxy](https://docs.cilium.io/en/v1.20/network/kubernetes/kubeproxy-free/)).
The guide uses the control plane's IP. `k3s.lan` (`k3s_api_name`) is used instead: it is how the
k3s agents and the kubeconfig already reach the API, the router's DNS points it at node02, the
server certificate carries it, and the k3s role checks all of that on every node before it
installs Cilium. Moving the control plane stays a DNS change, with nothing to edit here
(`docs/how-to/recover-control-plane.md`). The agents and operator run on the host network with
the default DNS policy, so they resolve it with the node's resolver, not with CoreDNS, which
needs Cilium first. The role fails if `k8sServiceHost` and `k3s_api_name` differ. The cost is
that an agent that restarts while the router's DNS is down cannot reach the API until it is back;
pods already running keep their networking. The guide recommends eBPF
masquerading with eBPF NodePort, so `bpf.masquerade: true`. Routing stays VXLAN tunnelling, as with
flannel, and pods keep k3s's range, `10.42.0.0/16` in /24s per node, through Cilium's cluster-pool
IPAM, as the k3s guide sets it. All nodes run kernel 7.0, well past what any of this needs.

### servicelb stays

k3s's servicelb (klipper-lb) keeps publishing ingress-nginx on ports 80 and 443 of each node, and
writing those node IPs into the Service's `status.loadBalancer.ingress`. It needs nothing from
kube-proxy for its own pods: they bind host ports, which Cilium's kube-proxy replacement serves
natively, and forward with iptables to the Service's ClusterIP, which Cilium translates. Traffic to
a node IP that is a LoadBalancer address is served by Cilium's eBPF load balancer in kube-proxy's
place, as the k3s docs describe kube-proxy doing
([k3s networking services](https://docs.k3s.io/networking/networking-services)). Neither doc covers
the pair together, so the rebuild checks it (curl to each node IP from the LAN).

### Mixed hardware, and ws03

Cilium publishes multi-arch images, so the arm64 RK1s and the amd64 NUCs and ws03 run the same
chart. The agent and Envoy DaemonSets tolerate every taint (the chart default), so they run on
node02 (control plane) and on ws03 (workstation taint), which must have pod networking for its GPU
and monitoring pods.

### The existing NetworkPolicies

Cilium implements Kubernetes NetworkPolicy, and four of the five policies only select pods and
namespaces, which it handles the same way. Like k3s's controller, it always admits traffic from a
pod's own node, so kubelet probes keep working
([Layer 3 policies](https://docs.cilium.io/en/v1.20/security/policy/)).

The fifth, `minecraft-dashboard-worlds`, admits RCON from LAN CIDRs but for the other cluster
nodes, and relies on ws03 (a node) being admitted. By default Cilium never matches a node's
address against a CIDR rule, so ws03 would lose RCON. `policyCIDRMatchMode: [nodes]` restores the
old behaviour. Pods on other nodes that reach the RCON NodePort now keep their own pod address
(socket load balancing), which no CIDR rule matches, so they are still refused.

### Hubble

Hubble, Hubble Relay and the Hubble UI are on. The UI is at `hubble.gkcluster.org`, through the
Cloudflare tunnel and behind oauth2-proxy (admin emails only), like Headlamp: it has no login of
its own and shows every flow in the cluster. Its Ingress is a separate `hubble-ui` Application,
because `cilium.yaml` must stay free of templates, and it exists only while
`enable_oauth2_proxy` is on. Flow metrics (DNS, drops, TCP, flows, ports, ICMP and policy
verdicts, labelled by namespace), the agent, Envoy, operator and Relay metrics go to the existing
Prometheus, and the chart's Grafana dashboards are on (ConfigMaps that Grafana's sidecar picks up).

### A first DNS-name egress rule

A CiliumNetworkPolicy, `backups-egress` in `additions/backups`, selects every pod in the `backups`
namespace and allows egress only to cluster DNS (through Cilium's DNS proxy) and, on port 443, to
the hosts the off-site jobs use: Google Drive (`www.googleapis.com`, `oauth2.googleapis.com`),
Backblaze B2 (`*.backblazeb2.com`, and `pod-*.backblaze.com` for uploads), and GitHub
(`github.com`, `release-assets.githubusercontent.com`). GitHub is there because both jobs' init
container downloads the pinned age release; a policy applies to the whole pod. The NFS volumes are
mounted by the kubelet on the node, so they are not pod egress. The Grafana and Jellyfin backup
jobs in the same namespace make no connections.

### Version

1.20.5, the newest 1.20 patch on 21 November 2026. Of the GitHub security advisories, only
GHSA-p5q6-g354-mxrg names a 1.20 release, fixed in 1.20.2. Renovate tracks the chart through the
Application, as for the other charts, but a Cilium bump is never automerged (`renovate.json`): it
restarts the agent on every node, and a minor bump needs its upgrade notes read first.

### Left out

WireGuard encryption, and L2 announcements in place of servicelb (issue #777). Native routing in
place of VXLAN, which would need every node on one L2 segment and gains little here.

## Consequences

- The move is a rebuild, with the outage that implies; `--tags k3s` on a flannel cluster stops
  with an error rather than break it.
- k3s's `kube-proxy` and flannel no longer exist, so their troubleshooting no longer applies;
  `cilium-dbg` in the agent pods and Hubble take their place.
- The Cilium agents, like the k3s agents, depend on `k3s.lan` resolving when they start.
- A node rebuilt after decommission may still hold Cilium's eBPF programs and state from the old
  cluster until it reboots; the new agent takes them over, and a reboot clears them.
- Phase 2 can add Cilium's Gateway API on top without touching the CNI again.
