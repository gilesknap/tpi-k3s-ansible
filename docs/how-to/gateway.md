# Check Cilium's Gateway

Cilium's Gateway `web` serves every hostname
({doc}`ADR 16 </explanations/decisions/0016-cilium-gateway-api>`): every
Cloudflare tunnel route goes to it, and servicelb gives it ports 80 and 443
on the node addresses (192.168.1.83, .84, .91 and .92, and those nodes'
tailnet addresses), which the `home-lan` and `home-tailnet` probes and the
VPS's `/mcp` use. Browsers at home use the tunnel like any other, as the
router has no local `*.gkcluster.org` names.

## Check the Gateway

```bash
kubectl get crd httproutes.gateway.networking.k8s.io
kubectl get gatewayclass cilium-gateway        # ACCEPTED True
kubectl -n gateway get gateway web             # PROGRAMMED True, ADDRESS the node IPs
kubectl get httproute -A                       # 16 routes
kubectl -n gateway get svc cilium-gateway-web  # EXTERNAL-IP the node IPs, no NodePorts
kubectl -n kube-system get ds | grep svclb     # cilium-gateway-web: 4 desired, 4 ready
```

`PROGRAMMED False` with "Gateway waiting for address" means servicelb has
listed no node on the Service: check its svclb pods
(`kubectl -n kube-system get pods -o wide | grep svclb-cilium-gateway-web`).
One stuck Pending usually means something else holds host port 80 or 443 on
that node. Envoy is configured all the same, so the tunnel still works.

From the LAN, each node address answers plain HTTP and HTTPS (the
wildcard certificate). Plain HTTP is served, not redirected, while the
tunnel is on, as cloudflared uses port 80 too (ADR 16):

```bash
for ip in 192.168.1.83 192.168.1.84 192.168.1.91 192.168.1.92; do
  curl -s -o /dev/null -w "$ip http %{http_code} " -H 'Host: echo.gkcluster.org' http://$ip/
  curl -s -o /dev/null -w "https %{http_code} verify=%{ssl_verify_result}\n" \
    --resolve home-lan.gkcluster.org:443:$ip https://home-lan.gkcluster.org/healthz
done
```

Inside the cluster, `argocd.gkcluster.org` resolves to the Gateway's
ClusterIP (the `coredns-custom` ConfigMap, written by the cluster role), so
Dex sign-in for ArgoCD, Grafana and ArgoCD Monitor goes through it:

```bash
kubectl -n kube-system get cm coredns-custom -o yaml   # the ClusterIP of cilium-gateway-web
kubectl -n home exec deploy/home -- curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' \
  https://argocd.gkcluster.org/api/dex/.well-known/openid-configuration   # 200 0
```

If the Gateway's Service was ever re-made, its ClusterIP changed: re-run
`ansible-playbook pb_all.yml --tags cluster` to rewrite the override.

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
