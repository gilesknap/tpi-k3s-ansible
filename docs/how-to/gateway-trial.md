# Trial Cilium's Gateway, one hostname at a time

Cilium's Gateway runs beside ingress-nginx and carries nothing until a
Cloudflare tunnel route is pointed at it
({doc}`ADR 16 </explanations/decisions/0016-cilium-gateway-api>`). This page
moves one hostname at a time, and back. Only the tunnel moves: the LAN names
(`home-lan`, `home-tailnet`) and the VPS keep reaching ingress-nginx until
phase 2.

## Check the Gateway first

After the change is running (merged, or the cluster switched to its branch
with `just switch-branch`):

```bash
kubectl get crd httproutes.gateway.networking.k8s.io
kubectl get gatewayclass cilium-gateway        # ACCEPTED True
kubectl -n gateway get gateway web             # PROGRAMMED False is expected
kubectl get httproute -A                       # 16 routes
kubectl -n gateway get svc cilium-gateway-web  # no EXTERNAL-IP, no NodePorts
kubectl -n kube-system get ds | grep svclb     # cilium-gateway-web: 0 desired
```

`PROGRAMMED False` with "Gateway waiting for address" is the Gateway being
kept off the node addresses on purpose; Envoy is configured all the same.

Every route should be accepted with its references resolved:

```bash
kubectl get httproute -A -o \
  jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .status.parents[*].conditions[*]}{.type}={.status} {end}{"\n"}{end}'
```

If `kubectl get gatewayclass` shows nothing accepted, the Cilium operator
probably started before the CRDs were there and left its Gateway API controller
off (its log says "Required GatewayAPI resources are not found"). Restart it
once:

```bash
kubectl -n kube-system logs deploy/cilium-operator | grep -i gatewayapi
kubectl -n kube-system rollout restart deployment/cilium-operator
```

## Move a hostname

Each move is one line in `tunnel_services` in `cloudflare/locals.tf`: add
`service = local.gateway`, which is
`http://cilium-gateway-web.gateway.svc.cluster.local`. Then plan and apply as
on any day ({ref}`cf-roll-apply-token`): `just cf-plan` must show one in-place
change to `cloudflare_zero_trust_tunnel_cloudflared_config.cluster`, that
hostname's `service` going from the ingress-nginx address to the Gateway's.
Roll the edit token at <https://dash.cloudflare.com/profile/api-tokens>, and
run `just cf-apply` from the main clone. cloudflared picks up the new route in
seconds. A response through the Gateway carries `server: envoy`.

In this order: echo first, then the services with no oauth2-proxy, then the
five behind it.

| Hostname | The line today | The line on the Gateway |
|----------|----------------|-------------------------|
| `echo` | `{ name = "echo" },` | `{ name = "echo", service = local.gateway },` |
| `home` | `{ name = "home" },` | `{ name = "home", service = local.gateway },` |
| `grafana` | `{ name = "grafana", service = "${local.ingress_nginx}:80" },` | `{ name = "grafana", service = local.gateway },` |
| `argocd-monitor` | `{ name = "argocd-monitor" },` | `{ name = "argocd-monitor", service = local.gateway },` |
| `argocd` | `{ name = "argocd" },` | `{ name = "argocd", service = local.gateway },` |
| `oauth2` | `{ name = "oauth2" },` | `{ name = "oauth2", service = local.gateway },` |
| `pages` | `{ name = "pages", cache = true, access_bypass = true },` | `{ name = "pages", cache = true, access_bypass = true, service = local.gateway },` |
| `ntfy` | `{ name = "ntfy", access_bypass = true },` | `{ name = "ntfy", access_bypass = true, service = local.gateway },` |
| `headlamp` | `{ name = "headlamp" },` | `{ name = "headlamp", service = local.gateway },` |
| `hubble` | `{ name = "hubble" },` | `{ name = "hubble", service = local.gateway },` |
| `alertmanager` | `{ name = "alertmanager" },` | `{ name = "alertmanager", service = local.gateway },` |
| `minecraft` | `{ name = "minecraft" },` | `{ name = "minecraft", service = local.gateway },` |
| `scrap` | `{ name = "scrap" },` | `{ name = "scrap", service = local.gateway },` |

The `scrap` line moves both scrap's app and its `/mcp` path.

## What to test

| Hostname | Test |
|----------|------|
| `echo` | The page loads, with `server: envoy` among the response headers. |
| `argocd` | The UI and its live application list; the `argocd` CLI with `--grpc-web`; Dex sign-in for Grafana and argocd-monitor still works (they reach Dex at `argocd.gkcluster.org`). |
| `ntfy` | A phone subscription stays connected for over 5 minutes and gets a test message (the JSON stream or WebSocket); publishing still needs a token. |
| `pages` | A public page loads with no sign-in. |
| `headlamp` | Pod logs and exec (WebSockets). |
| `hubble` | The flow list fills (gRPC-web, passed through). |
| `scrap` | An upload over a few MB; an MCP session from Claude that stays connected; a search. |
| each gated app | In a private window: the app's URL sends you through Cloudflare Access, then "Signing in with GitHub", GitHub, and back to the same URL. scrap shows the signed-in user. |

oauth2-proxy can stay on nginx while a gated app is on the Gateway: the
sign-in page sends the browser to `oauth2.gkcluster.org`, whichever serves it.

## Roll back

Put the line back as it was, `just cf-plan` (the same change the other way),
roll the edit token and `just cf-apply`. Nothing in the cluster changes either
way, so moving back is as quick as moving.

## When something fails

| Symptom | Likely cause |
|---------|--------------|
| `404` from Envoy | The route is not attached: `kubectl -n <ns> describe httproute <name>`. |
| `500` on a gated app | The ExternalAuth reference is refused: is the namespace in `external_auth_namespaces` (`kubernetes-services/templates/gateway.yaml`)? Or oauth2-proxy is down. |
| `503`, or a connection reset | A NetworkPolicy drops Envoy: `kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --identity ingress --verdict DROPPED`. |
| A request cut after 5 minutes of quiet | Envoy's stream idle timeout ({doc}`ADR 16 </explanations/decisions/0016-cilium-gateway-api>`). |
| A sign-in loop | Check that `rd` in the address bar is the app's URL, and oauth2-proxy's log. |
