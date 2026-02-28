# Set Up a Cloudflare Tunnel

This guide walks through setting up a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
to expose selective cluster services to the internet, while keeping most services
LAN-only. It also covers DNS-01 certificate issuance via the Cloudflare API.

## Architecture

```
INTERNET
  │
  ▼
Cloudflare Edge (WAF, DDoS protection, CDN)
  │  DNS: echo.<domain> → <tunnel>.cfargotunnel.com  (Proxied)
  │  HTTPS (Cloudflare manages external TLS)
  ▼
cloudflared pod (in cluster, outbound connection only — no inbound firewall ports)
  │  HTTP to ingress-nginx
  ▼
ingress-nginx → service

LOCAL NETWORK
  DNS: grafana/argocd/headlamp/longhorn/rkllama.<domain> → worker IP  (DNS-only A records)
  Clients resolve directly to ingress-nginx without going via Cloudflare
```

**Key design decisions:**

- Only explicitly configured services are publicly accessible through the tunnel.
  All other services use grey-cloud (DNS-only) A records — accessible from LAN only.
- **No wildcard CNAME** in Cloudflare DNS to avoid ECH (Encrypted Client Hello)
  issues in Chrome (`ERR_ECH_FALLBACK_CERTIFICATE_INVALID`).
- **DNS-01 challenge** for TLS certificates — works for all hostnames including
  LAN-only services that have no public HTTP route.
- `cloudflared` uses an **outbound-only** connection — no inbound firewall ports needed.

## Part 1: Cloudflare web UI setup

### 1.1 Add your domain

If your domain is registered elsewhere, delegate DNS to Cloudflare by updating
nameservers at your registrar.

1. Log in to the [Cloudflare dashboard](https://dash.cloudflare.com).
2. Use **Onboard a Domain** or **Buy a Domain**.
3. Wait for DNS propagation (usually minutes to an hour).

### 1.2 Create a tunnel

1. Navigate to **Networking → Tunnels**.
2. Click **Create a tunnel**.
3. Select **Cloudflared** as the connector type.
4. Name the tunnel (e.g. `k3s-cluster`).
5. After creation, Cloudflare shows setup instructions. Copy the **tunnel token**
   from the "Install as service" box.

```{figure} ../images/tunnels.png
:alt: Cloudflare tunnel configuration
:align: center

The Cloudflare Tunnels dashboard after creating a tunnel.
```

Extract just the token value (the long base64 string after `--token`).

### 1.3 Deploy cloudflared first

Cloudflare's UI will not let you continue until it detects a live tunnel connection.
You must deploy the cloudflared pod **now**.

Create a SealedSecret from the token:

```bash
printf 'Tunnel token: ' && read -rs TOKEN && echo
printf '%s' "$TOKEN" | \
  kubectl create secret generic cloudflared-credentials \
    --namespace cloudflared \
    --from-file=TUNNEL_TOKEN=/dev/stdin \
    --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
    kubernetes-services/additions/cloudflared/tunnel-secret.yaml
unset TOKEN
```

Commit and push:

```bash
git add kubernetes-services/additions/cloudflared/tunnel-secret.yaml
git commit -m "Add cloudflared tunnel token SealedSecret"
git push
```

ArgoCD syncs the `cloudflared` Application. Watch the pod start:

```bash
kubectl rollout status deployment/cloudflared -n cloudflared
kubectl logs -n cloudflared deployment/cloudflared | tail -20
```

Once connected, the Cloudflare UI shows **"Tunnel connected successfully"**.

```{figure} ../images/tunnel_success.png
:alt: Tunnel connected successfully
:align: center

Cloudflare confirming the tunnel connection is established.
```

### 1.4 Configure a public hostname

In the tunnel details, click **Routes → Add a route → Published Application**.

For the echo test service:

| Field | Value |
|---|---|
| Subdomain | `echo` |
| Domain | `example.com` |
| Service URL | `http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local:80` |

:::{important}
Use **HTTP** (not HTTPS) for the service URL. Cloudflare terminates external TLS at its
edge. If the tunnel also used HTTPS and ingress-nginx forced a redirect, it would cause
a redirect loop. The echo ingress has `ssl-redirect: false` to match.
:::

### 1.5 DNS record created automatically

Cloudflare creates a proxied CNAME:

```
echo.example.com → <tunnel-id>.cfargotunnel.com  (Proxied ☁)
```

:::{warning}
**Do not add a wildcard `*` CNAME record.** A proxied wildcard causes Cloudflare to
publish HTTPS DNS records advertising ECH for every subdomain. Chrome will attempt ECH
for subdomains like `grafana.example.com` via Cloudflare's edge, but Cloudflare has no
cert for it — resulting in `ERR_ECH_FALLBACK_CERTIFICATE_INVALID`.

Instead, add explicit grey-cloud A records for each LAN-only service (see Part 3).
:::

### 1.6 Create an API token for DNS-01

cert-manager needs a Cloudflare API token to manage `_acme-challenge` TXT records.

1. Go to **Manage Account → Account API Tokens → Create Token**.
2. Use the **Edit zone DNS** template.
3. Configure:

| Setting | Value |
|---|---|
| Permissions | Zone → DNS → Edit |
| Zone Resources | Include → Specific zone → your domain |

4. Create the token and **copy it immediately** (shown only once).

## Part 2: WAF (Web Application Firewall)

Cloudflare's built-in protections (DDoS mitigation, bot management, managed rulesets)
apply automatically to all proxied traffic. **No custom security rules are needed**
for this setup.

Custom WAF rules are only necessary if you add a wildcard CNAME (which you should
not — see the warning in Part 1.5). Without a wildcard, only explicitly tunnelled
hostnames receive traffic from the internet, so Cloudflare's defaults are sufficient.

### Optional: rate limiting

If you want to limit request rates on tunnelled services, add a rate-limiting rule:

1. Go to **Security → WAF → Rate Limiting Rules**.
2. Create a rule:

| Field | Value |
|---|---|
| Rule name | `Echo rate limit` |
| Match | Hostname equals `echo.example.com` |
| Rate | 30 requests per 1 minute |
| Action | Block |

## Part 3: DNS records for LAN-only services

For services not exposed via the tunnel, add **grey-cloud (DNS-only) A records**:

| Type | Name | Content | Proxy status |
|------|------|---------|-------------|
| A | `argocd` | `192.168.1.82` | DNS only |
| A | `grafana` | `192.168.1.82` | DNS only |
| A | `headlamp` | `192.168.1.82` | DNS only |
| A | `longhorn` | `192.168.1.82` | DNS only |
| A | `oauth2` | `192.168.1.82` | DNS only |
| A | `open-webui` | `192.168.1.82` | DNS only |
| A | `rkllama` | `192.168.1.82` | DNS only |

Use one of the worker node IPs. These resolve to a private RFC-1918 address — only
reachable from your LAN.

:::{note}
Adding records in Cloudflare (rather than your router) means they work for any client
using Cloudflare's public nameservers, without router-side DNS configuration. It also
keeps all DNS for the domain in one place.
:::

## Part 4: Kubernetes secrets

### 4.1 Cloudflare API token secret

Using the API token from Step 1.6:

```bash
printf 'Cloudflare API token: ' && read -rs TOKEN && echo
printf '%s' "$TOKEN" | \
  kubectl create secret generic cloudflare-api-token \
    --namespace cert-manager \
    --from-file=api-token=/dev/stdin \
    --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
    kubernetes-services/additions/cert-manager/cloudflare-api-token-secret.yaml
unset TOKEN
```

Commit and push:

```bash
git add kubernetes-services/additions/cert-manager/cloudflare-api-token-secret.yaml
git commit -m "Add cert-manager Cloudflare DNS-01 API token SealedSecret"
git push
```

### 4.2 cert-manager ClusterIssuer

The `ClusterIssuer` at `kubernetes-services/additions/cert-manager/issuer-letsencrypt-prod.yaml`
uses DNS-01 with Cloudflare:

```yaml
solvers:
  - dns01:
      cloudflare:
        apiTokenSecretRef:
          name: cloudflare-api-token
          key: api-token
```

This works for **all** certificates — including LAN-only services. cert-manager adds
a temporary `_acme-challenge` TXT record via the Cloudflare API, waits for Let's Encrypt
to validate it, then removes the record.

## Part 5: Verification

### Check certificates

```bash
kubectl get certificate -A
```

All certificates should show `READY: True`.

### Check cloudflared connectivity

```bash
kubectl logs -n cloudflared deployment/cloudflared | tail -30
```

Look for `Connection registered` and `Registered tunnel connection`.

### Test public access

```bash
curl https://echo.example.com
```

Expected: JSON response from the echo server.

### Confirm LAN-only isolation

From outside your LAN (e.g. mobile hotspot):

```bash
curl -I https://argocd.example.com
# Expected: connection refused or timeout (private IP not reachable)
```

From inside your LAN:

```bash
curl -I https://argocd.example.com
# Expected: 200/302 ArgoCD login page
```

### Check ArgoCD app status

```bash
kubectl get applications -n argo-cd
```

All applications should be `Synced` and `Healthy`.

## Making a LAN-only service externally accessible

To move a service from LAN-only to publicly accessible through the tunnel:

1. **Add a public hostname in the tunnel.** In the Cloudflare dashboard, go to
   **Networking → Tunnels → your tunnel → Public Hostname → Add a public hostname**.

   | Field | Value |
   |---|---|
   | Subdomain | e.g. `grafana` |
   | Domain | `example.com` |
   | Service URL | `http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local:80` |

   Use HTTP, not HTTPS — Cloudflare terminates TLS at its edge.

2. **Delete the grey-cloud A record** for that subdomain in **DNS → Records**.
   Cloudflare creates a proxied CNAME automatically when you add the tunnel hostname.
   If you leave the A record in place it takes precedence over the tunnel CNAME,
   and external clients get the unreachable private IP.

3. **Disable ssl-redirect on the Ingress.** Traffic arriving through the tunnel is
   already HTTP (Cloudflare handles external TLS). If ingress-nginx forces an HTTPS
   redirect, it causes a redirect loop. Add the annotation:

   ```yaml
   nginx.ingress.kubernetes.io/ssl-redirect: "false"
   ```

4. **Consider authentication.** A service on the LAN may not have required auth.
   Once it is public, protect it with one of:
   - **Cloudflare Access** (Zero Trust) — authentication at the Cloudflare edge,
     zero cluster overhead. See {doc}`cloudflare-ssh-tunnel` for an example.
   - **oauth2-proxy** — in-cluster OAuth. See {doc}`oauth-setup`.

5. **Optionally add a rate-limiting rule** in **Security → WAF → Rate Limiting Rules**
   for the newly public hostname.

### Reverting to LAN-only

To take a service back off the internet:

1. Delete the public hostname from the tunnel configuration.
2. Delete the proxied CNAME that Cloudflare created.
3. Re-add the grey-cloud A record pointing to your worker IP.
4. Remove the `ssl-redirect: "false"` annotation if it was only added for the tunnel.

## Cloudflare Access integration

For services that need authentication before reaching the cluster, use
Cloudflare Access (part of Zero Trust). This adds identity verification
at the Cloudflare edge with zero cluster overhead.

See {doc}`cloudflare-ssh-tunnel` for a working example with SSH, and
{doc}`oauth-setup` for in-cluster OAuth as an alternative.

## Troubleshooting

See the Cloudflare Tunnel section in the {doc}`/reference/troubleshooting`
guide for common issues and solutions.
