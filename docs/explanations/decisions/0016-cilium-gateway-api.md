# 16. Cilium's Gateway API Replaces ingress-nginx

**Status:** Proposed. The first of two PRs is in: the Gateway runs beside
ingress-nginx and carries every Cloudflare tunnel route, while ingress-nginx
keeps the node addresses. Phase 2 (removing ingress-nginx) marks this
Accepted.

## Context

ingress-nginx went end-of-life upstream in March 2026 and gets no more CVE
fixes. Phase 1 (ADR 0015) made Cilium the CNI so that its Gateway API
implementation, which runs on the Envoy that Cilium already deploys, can take
over. The owner's decisions are in issue #781: oauth2-proxy stays the login
gate, through Gateway API's ExternalAuth filter; the Gateway does not touch the
node addresses until ingress-nginx is gone; and traffic moves by pointing the
Cloudflare tunnel routes at the Gateway, which can be done, and undone, one
hostname at a time.

There are 16 Ingresses: echo, home, home-lan, home-tailnet, grafana,
alertmanager, argocd, argocd-monitor, headlamp, hubble, minecraft, ntfy,
oauth2, pages, scrap, and scrap's `/mcp`. Five are behind oauth2-proxy:
headlamp, alertmanager, minecraft, scrap and hubble (the last added by phase 1).

## Decision

### The Gateway API CRDs

The **experimental** channel of Gateway API **v1.6.3**. ExternalAuth (GEP-1494)
is in the experimental CRDs only: the standard `HTTPRoute` schema has no
`externalAuth` field. v1.6.3 is the version Cilium 1.20.5 is built and
documented against (`gateway_api_version` in its
[Documentation/conf.py](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/conf.py);
the [1.20.0 release notes](https://github.com/cilium/cilium/releases/tag/v1.20.0)
name v1.6.1 and list ExternalAuth as new). Cilium needs GatewayClass,
Gateway, HTTPRoute, GRPCRoute, BackendTLSPolicy, ReferenceGrant and TLSRoute
([Gateway API support](https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/gateway-api/));
the bundle has those and the optional ones.

The one copy of the version is `kubernetes-services/additions/gateway-api-crds/kustomization.yaml`,
a kustomize build of the upstream `config/crd/experimental` at that tag (the
same content as the release's `experimental-install.yaml`, which at 1.4 MB is
too big to vendor past the large-file hook). Two things apply it:

- **ArgoCD**, through the `gateway-api-crds` Application, with server-side
  apply (the HTTPRoute CRD is too big for the last-applied annotation), no
  pruning and no resources finalizer: deleting a CRD deletes every object made
  from it.
- **The k3s role**, on a new cluster, before it installs Cilium
  (`roles/k3s/tasks/cilium.yml`). The Cilium operator checks for the CRDs once,
  when it starts, and if they are missing it leaves its Gateway API controller
  off until it restarts (`operator/pkg/gateway-api/cell.go`). The role applies
  the same kustomize build with ArgoCD's own field manager,
  `argocd-controller`, so ArgoCD adopts the CRDs without a field-ownership
  conflict, as it adopts Cilium.

On the running cluster the CRDs arrive through ArgoCD at the same time as the
new Cilium values that restart the operator. If the operator wins that race,
it must be restarted once (`docs/how-to/gateway.md`).

### Cilium

`gatewayAPI.enabled: true` in `kubernetes-services/templates/cilium.yaml`.
`gatewayAPI.gatewayClass.create: false`: the GatewayClass is the cluster's own
(below), and without the chart's class the chart renders the same whether or
not the CRDs exist, which the default `auto` does not.

Enabling it changes more than the Gateway. The chart also turns on
`enable-envoy-config`, and forces `bpf-lb-sock-hostns-only: true` and
`bpf-lb-algorithm-annotation: true` (`templates/cilium-configmap.yaml` in the
1.20.5 chart, for TCPRoute and UDPRoute weights). With the first, Cilium's
socket-level load balancing serves only host processes: a pod's connection to
a Service is translated per packet in eBPF at its interface instead of when
it connects. Services still never touch iptables, and pods keep their own
identity to the backend, which the Minecraft RCON policy relies on (ADR
0015). Every agent and the operator restart for the new values.

### One GatewayClass and one Gateway

`additions/gateway`, synced by the `gateway` Application into the `gateway`
namespace:

- **GatewayClass `cilium-gateway`**, with a `CiliumGatewayClassConfig`:
  - gRPC-web translation **off**. Cilium's Envoy otherwise turns gRPC-web
    requests into gRPC before they reach the backend
    ([Cilium #31933](https://github.com/cilium/cilium/issues/31933)), which
    breaks backends that speak gRPC-web themselves: ArgoCD's server, and Hubble
    UI's backend. ingress-nginx passes them through
    ([GatewayClass parameters](https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/parameterized-gatewayclass/)).
  - `allocateLoadBalancerNodePorts: false`, so the Gateway's Service takes no
    NodePorts, which Cilium would serve on every node address (and which could
    take a port the Minecraft worlds want).
- **Gateway `web`**, with two listeners for `*.gkcluster.org`: port 80, plain
  HTTP, which is what cloudflared sends; and port 443 with the wildcard
  certificate, for direct clients once the Gateway has the node addresses.
  The certificate stays in `cert-manager/wildcard-tls`; a ReferenceGrant there
  lets the Gateway use it, and Cilium copies it into `cilium-secrets` for Envoy.
  Routes may attach from any namespace, as any namespace can use the nginx
  IngressClass today.

Cilium makes the Service `cilium-gateway-web` in `gateway`. Its in-cluster
address, `http://cilium-gateway-web.gateway.svc.cluster.local`, is
`local.gateway` in `cloudflare/locals.tf`, the default for every tunnel
route.

### Keeping the Gateway off nginx's ports

The Gateway's Service is a LoadBalancer, and k3s's servicelb would serve it as
it serves ingress-nginx's: a svclb pod on every node, bound to host ports 80
and 443, the ones nginx's svclb pods hold. Options considered:

- **Service type ClusterIP or NodePort** through the CiliumGatewayClassConfig.
  ClusterIP is not allowed (`LoadBalancer` or `NodePort` only); NodePort puts the
  Gateway on high ports of every node address.
- **A `loadBalancerClass` that nothing implements.** servicelb ignores such a
  Service, but the field is immutable, so phase 2 would have to recreate the
  Service.
- **Different listener ports** (8080, 8443). They would be published on every
  node address, and phase 2 would have to change every listener.
- **servicelb's node pool label** on the Service, through the Gateway's
  `spec.infrastructure.labels`, which Cilium copies to the Service. Chosen.

With `svccontroller.k3s.cattle.io/lbpool: gateway-standby`, servicelb gives its
DaemonSet for this Service a node affinity for that pool
([ServiceLB node pools](https://docs.k3s.io/networking/networking-services#creating-servicelb-node-pools);
`pkg/cloudprovider/servicelb.go` in k3s v1.34 sets the affinity from the
Service's label alone). No node is in the pool, so no svclb pod runs, no host
port is taken, and the Service has a ClusterIP and no external address. The
cost: the Gateway reports `Programmed: False` ("waiting for address") and
ArgoCD shows the `gateway` Application as Progressing until phase 2. Envoy is
configured all the same; Cilium writes the listeners whether or not the
Service has an address (`operator/pkg/gateway-api/gateway_reconcile.go`).

Phase 2 sets the label to `""`. Removing it would not do: Cilium merges the
infrastructure labels onto its Service and never deletes one
(`setMergedLabelsAndAnnotations` in `operator/pkg/gateway-api`), and servicelb
treats an empty pool as no pool. servicelb only re-renders a Service's
DaemonSet when the Service's annotations change, not its labels (the
cloud-provider service controller's `needsUpdate`), so the same commit adds or
changes an infrastructure annotation.

### One HTTPRoute per Ingress

The ingress sub-chart, `additions/ingress`, emits an HTTPRoute beside each
Ingress, from the same values, so each app keeps one place to change. New
values: `http_route` (default on), `ingress` (default on; off for the four
whose Ingress comes from elsewhere: Alertmanager's and oauth2-proxy's from
their charts, pages from the scrap chart, ArgoCD's from the cluster role),
and `namespace` (pages lives in `scrap-public`). Those four use the sub-chart
for the route alone: Alertmanager in the grafana Application, oauth2 in the
oauth2-proxy one, pages in scrap's, and ArgoCD in the gateway Application.
scrap's `/mcp` route sits beside its Ingress in `additions/scrap`. The route
templates render only when the HTTPRoute CRD exists
(`.Capabilities.APIVersions`), so no Application fails its first sync on the
running cluster while the CRDs are still on their way; a new cluster has them
from the k3s role.

How the nginx annotations map:

| Annotation | Where | On the Gateway |
|------------|-------|----------------|
| `ssl-redirect` | all, `"false"` with the tunnel on | Off: the route attaches to both listeners. On: the route attaches to the HTTPS listener only, and a second route on the HTTP listener answers with a `RequestRedirect` to HTTPS. Phase 2 decides the LAN redirect. |
| `auth-url`, `auth-signin`, `auth-response-headers` | the five gated apps | The ExternalAuth filter, below |
| `proxy-body-size` | scrap and `/mcp` (50m), ntfy (64k) | None. Envoy streams the body and sets no limit; Gateway API and Cilium have no field for one. scrap and ntfy keep their own limits (ntfy's messages are at most 4k, attachments off). |
| `proxy-buffering: off`, `proxy-request-buffering: off` | ntfy, `/mcp` | None needed: Envoy streams both ways ([Cilium's annotation guide](https://docs.cilium.io/en/v1.20/network/servicemesh/ingress-to-gateway/nginx-annotations-migration/) lists buffering as dropped). |
| `proxy-read-timeout`, `proxy-send-timeout` | ntfy (180 s), `/mcp` (3600 s) | `timeouts.request: 0s` on the routes of apps that stream or run long requests, below |

The timeouts need care in the other direction. Envoy's route timeout defaults
to 15 s for the whole response
([RouteAction.timeout](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto)),
and Cilium leaves it at that default when a route sets no timeout
(`operator/pkg/model/translation/envoy_virtual_host.go`). nginx has no
whole-response limit, only one between reads. So the route of each app that
streams or runs long requests sets `timeouts.request: 0s`, which turns the
route timeout off ([GEP-1742](https://gateway-api.sigs.k8s.io/geps/gep-1742/)):
ntfy's subscriptions, Headlamp's, Grafana's and Hubble UI's live streams,
ArgoCD's watch streams, the log streams of argocd-monitor and the Minecraft
dashboard, and scrap's uploads, attachment downloads and MCP event streams
(its public pages too). The ingress sub-chart's `gateway_request_timeout`
value sets it. The rest (echo, home, oauth2-proxy, Alertmanager) keep Envoy's
15 s, which bounds a request that hangs. For the streaming apps what is left
is Envoy's idle timeout for a stream, 5 minutes for all of Cilium's Envoy
(`envoy.streamIdleTimeoutDurationSeconds`): longer than ntfy's 180 s (its
clients send keepalives every 45 s), shorter than `/mcp`'s 3600 s. MCP clients
reconnect, and an MCP session from Claude worked in the trial.

### ExternalAuth against oauth2-proxy

nginx's `auth-url` calls oauth2-proxy's `/oauth2/auth` for each request; on a
401 nginx redirects the browser to `auth-signin`
(`oauth2.gkcluster.org/oauth2/start?rd=<the URL>`), and on a 2xx it copies
`X-Auth-Request-User` and `X-Auth-Request-Email` into the request. Cilium turns
the ExternalAuth filter into Envoy's `ext_authz` in HTTP mode
([ext_authz](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_authz_filter)),
which differs in three ways, and the wiring follows from them:

- **Only a 200 allows the request** (GEP-1494's HTTP protocol), and anything
  else is sent back to the client as the answer. `/oauth2/auth` answers 202,
  and a bare 401 the browser cannot act on. So the filter does not use it. It
  sends the request to oauth2-proxy's catch-all proxy handler, which with
  `upstream: static://200` answers 200 to a signed-in request, and for a
  browser with no session answers 403 with its sign-in page
  ([endpoints](https://oauth2-proxy.github.io/oauth2-proxy/features/endpoints)).
  The upstream was `static://202`; nothing used it, as nginx calls
  `/oauth2/auth`, which answers 202 regardless.
- **The path.** ext_authz sends the client's path to the auth service,
  behind an optional prefix. Unprefixed, a request for an app's `/ping`,
  `/robots.txt`, `/oauth2/static/...` or `/oauth2/sign_in` would reach
  oauth2-proxy's own handlers, which answer 200 with no session, and Envoy
  would let it through. The filter therefore sets `path: /gateway-auth`, so
  every check lands on the catch-all handler. A local run of oauth2-proxy
  v7.15.6 answers those paths 200 unprefixed and 403 prefixed.
- **No redirect on denial.** The sign-in page is the denial, served at the
  app's own URL. A custom `sign_in.html` (in
  `additions/oauth2-proxy/error-templates.yaml`) does what `auth-signin` did:
  it sends the browser to `oauth2.<domain>/oauth2/start` with `rd` set to the
  page's own address. Login must start on the oauth2 host, as that is the
  GitHub OAuth app's callback. oauth2-proxy still checks `rd` against
  `whitelist-domain`.

Headers:

- **To oauth2-proxy:** only `Cookie` (the session), on top of what ext_authz
  always sends (`Host`, method, path, `Authorization`). No body.
- **Back to the app:** only `X-Auth-Request-User` and `X-Auth-Request-Email`.
  With an empty list Cilium would copy every response header, including the
  user's GitHub access token in `X-Auth-Request-Access-Token`
  (`pass-access-token`). Envoy replaces a client's header of the same name
  with oauth2-proxy's, so a client cannot claim another identity. Unlike
  nginx, which always sets them (empty if absent), a header oauth2-proxy does
  not return would pass through from the client; it returns both for every
  session, as the GitHub provider and the email allow list need an email.

The backend reference crosses namespaces, so a ReferenceGrant in
`oauth2-proxy` names the namespaces whose routes may use it (in the gateway
Application). A gated route in a namespace left out gets a 500, and one whose
check cannot reach oauth2-proxy a 403 (Envoy's default on error, which Cilium
does not change): the filter fails closed either way.

The filter depends on the experimental CRDs. A standard-channel HTTPRoute CRD
applied over them would drop the `externalAuth` field, and Cilium skips an
ExternalAuth filter with no body, so the gated routes would serve without
oauth2-proxy. The upstream safe-upgrades policy in the bundle refuses only the
opposite move, so nothing in the cluster may install standard-channel Gateway
API CRDs.

Grafana, ArgoCD and argocd-monitor keep their own logins (Dex) and need
nothing from the Gateway.

### NetworkPolicies

Envoy reaches backends as Cilium's reserved `ingress` identity, not from a pod
in `ingress-nginx`, so the policies that admit only that namespace (scrap,
scrap's public pages, ntfy) would drop the Gateway's requests. A
CiliumNetworkPolicy beside each admits `fromEntities: [ingress]` on the same
port
([Ingress and network policy](https://docs.cilium.io/en/v1.20/network/servicemesh/ingress-and-network-policy/),
[entities](https://docs.cilium.io/en/v1.20/security/policy/layer3/#entities-based)).

## Consequences

- The tunnel reaches the Gateway, while the node addresses (`home-lan`,
  `home-tailnet` and the VPS) still reach ingress-nginx, and every Ingress
  renders as before. Browsers at home use the tunnel too: the router has no
  local `*.gkcluster.org` names. The change restarts every Cilium agent and
  the operator (new values), and oauth2-proxy (new upstream).
- The `gateway` Application stays Progressing until phase 2 gives the Gateway
  an address; `/rebuild-cluster` counts that as healthy until then.
- The custom sign-in page replaces oauth2-proxy's everywhere, so on
  `oauth2.gkcluster.org` itself the "Sign in with GitHub" button is gone and
  the page goes straight to GitHub. A sign-out that lands there signs straight
  back in while the GitHub session lasts. Nothing links to sign-out today.
- Envoy does not merge `..` path segments as nginx does (Cilium sets no path
  normalisation), so `scrap.gkcluster.org/mcp/../x` matches the `/mcp` route,
  which has no oauth2-proxy; scrap then sees the path unchanged.
  `docs/how-to/gateway.md` has the check.
- The trial moved all 13 tunnel routes to the Gateway in one `just cf-apply`
  on 22 Nov 2026, and every app passed: sign-in on the five gated apps, ntfy
  to a phone, scrap's MCP, Hubble and ArgoCD. A route can go back to
  ingress-nginx with a one-line change in `cloudflare/locals.tf` until phase
  2 (`docs/how-to/gateway.md`).
- A new gated app needs its namespace added to the oauth2-proxy
  ReferenceGrant's list in `templates/gateway.yaml`, or it fails closed.
- Gateway API upgrades follow Cilium's supported version and are not
  automerged.
- Not covered: HTTP/2 and gRPC to backends (`enableAppProtocol`), and access
  logs.

### Left for phase 2

Removing ingress-nginx and its Ingresses; dropping the lbpool label so the
Gateway takes the node addresses (LAN, `home-lan`, `home-tailnet`, and the
VPS on nuc2's tailnet address); the LAN HTTPS redirect; the `coredns-custom`
override for `argocd.gkcluster.org`, which points at nginx's ClusterIP; and a
`/rebuild-cluster` test.
