# Check Cilium's Gateway, and move a route back to ingress-nginx

Every Cloudflare tunnel route goes to Cilium's Gateway
({doc}`ADR 16 </explanations/decisions/0016-cilium-gateway-api>`): all 13
moved in one `just cf-apply` on 22 Nov 2026. ingress-nginx still runs beside
it and answers on the node addresses, which only the `home-lan` and
`home-tailnet` probes and the VPS's `/mcp` use, until phase 2 removes it.
Browsers at home use the tunnel like any other, as the router has no local
`*.gkcluster.org` names.

## Check the Gateway

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

After a change to the gated routes or to oauth2-proxy, check from a node that
the Gateway refuses a request with no session, whatever identity header it
carries (Cloudflare Access would hide a filter that lets requests through):

```bash
ip=$(kubectl -n gateway get svc cilium-gateway-web -o jsonpath='{.spec.clusterIP}')
ssh ansible@node03 "curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: scrap.gkcluster.org' -H 'X-Auth-Request-Email: someone@example.com' \
  http://$ip/"
```

It must print `403` (the sign-in page). For scrap, also try a path that
climbs out of `/mcp`, which Envoy does not normalise (add `--path-as-is`, or
curl normalises it first), such as `http://$ip/mcp/../` with the same headers:
it must not return scrap's app without the MCP bearer token.

## Move a route back to ingress-nginx

In an emergency, a hostname that fails on the Gateway can go back to
ingress-nginx, which still has every Ingress. Add its address to the entry in
`tunnel_services` in `cloudflare/locals.tf`:

```hcl
{ name = "scrap", service = "http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local" },
```

To move the whole tunnel, change the default in `tunnel_ingress`
(`lookup(s, "service", local.gateway)`) to that address instead. Then plan
and apply as on any day ({ref}`cf-roll-apply-token`): `just cf-plan` must show
one in-place change to `cloudflare_zero_trust_tunnel_cloudflared_config.cluster`,
the hostname's `service` going from the Gateway's address to nginx's. Roll the
edit token at <https://dash.cloudflare.com/profile/api-tokens>, and run
`just cf-apply` from the main clone. cloudflared picks up the route in
seconds, and nothing in the cluster changes. A response through the Gateway
carries `server: envoy`; one through nginx does not. Undo the edit the same
way once the Gateway is fixed. This works only until phase 2 removes
ingress-nginx.

## When something fails

| Symptom | Likely cause |
|---------|--------------|
| `404` from Envoy | The route is not attached: `kubectl -n <ns> describe httproute <name>`. |
| `500` on a gated app | The ExternalAuth reference is refused: is the namespace in `external_auth_namespaces` (`kubernetes-services/templates/gateway.yaml`)? |
| `403` on a gated app, with no sign-in page | Envoy could not reach oauth2-proxy (it fails closed): check its pods. |
| `503`, or a connection reset | A NetworkPolicy drops Envoy: `kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --identity ingress --verdict DROPPED`. |
| A `504` (`upstream request timeout`) after 15 s | The app streams or runs long requests: set `gateway_request_timeout: 0s` in its `additions/ingress` values ({doc}`ADR 16 </explanations/decisions/0016-cilium-gateway-api>`). |
| A request cut after 5 minutes of quiet | Envoy's stream idle timeout ({doc}`ADR 16 </explanations/decisions/0016-cilium-gateway-api>`). |
| A sign-in loop | Check that `rd` in the address bar is the app's URL, and oauth2-proxy's log. |
