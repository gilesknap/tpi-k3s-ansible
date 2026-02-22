# Bootstrap the Cluster

After the Ansible playbook completes, ArgoCD is installed and will begin syncing all
services. This guide covers the post-deployment steps: setting up credentials and
accessing each service.

## Fixed DHCP Leases

These first two steps involve configuring your router.

Before setting up DNS, assign **fixed DHCP leases** (also called "static leases" or
"address reservations") to each node in your router's DHCP settings. This ensures
nodes always receive the same IP address after a reboot — without fixed leases, your
DNS records could become stale.

Find your nodes' MAC addresses with `ip link` or `arp -a`, then map each one to a
static IP in your router's admin interface (e.g. `192.168.1.82`, `.83`, `.84`).

:::{tip}
At commissioning time, the nodes will have been given names `node01`, `node02`, etc,
using mDNS.

You can use these names to identify them in your router and then assign fixed IPs
accordingly.
:::

## DNS Prerequisites

Each service with an ingress needs a DNS A record pointing to your **worker node IPs**
(not the control plane). For single-node clusters, point to that node's IP.

The following services require DNS entries:

| DNS Name | Service | Auth |
|----------|---------|------|
| `argocd.<domain>` | ArgoCD (SSL passthrough) | admin + shared password |
| `grafana.<domain>` | Grafana dashboards | admin + shared password |
| `longhorn.<domain>` | Longhorn storage UI | admin + shared password (basic-auth) |
| `headlamp.<domain>` | Headlamp dashboard | Kubernetes token |
| `rkllama.<domain>` | RKLlama LLM server | None |
| `open-webui.<domain>` | Open WebUI chat interface | Account registration |

:::{note}
The **echo** service is not included in local DNS — it is intended as a public-facing
service exposed via the Cloudflare tunnel. Its only purpose is to test the tunnel and
demonstrate an externally accessible service. It becomes available after completing the
{doc}`cloudflare-tunnel` setup.
:::

For high availability, create **one A record per worker node** for each hostname so
that `kube-proxy` can route to the ingress pod regardless of which worker receives
the request:

| Type | Name | Content |
|------|------|---------|
| A | `argocd` | `192.168.1.82` |
| A | `argocd` | `192.168.1.83` |
| A | `argocd` | `192.168.1.84` |
| etc | ... | ... |

:::{tip}
If your DNS provider supports wildcard records, a single `*.<domain>` record per
worker is much simpler:

```
*.<domain>  A  192.168.1.82
*.<domain>  A  192.168.1.83
*.<domain>  A  192.168.1.84
```
:::

## Access ArgoCD

### Before DNS is working (port-forward)

```bash
kubectl port-forward svc/argocd-server -n argo-cd 8080:443
```

Open **https://localhost:8080** in your browser (accept the self-signed certificate warning).

Get the initial admin password:

```bash
kubectl -n argo-cd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Login with username `admin` and the password above.

### After DNS is working (ingress)

Access ArgoCD directly at **https://argocd.your-domain.com**.

### Using the helper script

The `tools` role creates port-forward helper scripts in your `$BIN_DIR`:

```bash
argo.sh
```

This starts a port-forward in the background and prints the URL and initial password.

## Watch ArgoCD sync

After logging in, you will see the `all-cluster-services` app-of-apps and its child
applications. They sync automatically — allow a few minutes for all services to reach
`Synced / Healthy`.

If any applications are stuck, force a refresh:

```bash
kubectl patch application all-cluster-services -n argo-cd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Set up the shared admin password

Several services share a common admin password via a Kubernetes secret called `admin-auth`.
This secret is **not managed by ArgoCD** — it is created manually and persists across syncs.

| Service   | How it uses `admin-auth`                          |
|-----------|---------------------------------------------------|
| ArgoCD    | Admin password set via `argocd-secret` patch      |
| Grafana   | `admin.existingSecret` references `admin-auth`    |
| Longhorn  | nginx basic-auth on ingress                       |

:::{note}
Headlamp uses its own Kubernetes token authentication — it does not use the shared
admin password. RKLlama and echo are intentionally unauthenticated.
:::

### Create the secrets

```bash
# Prompt for password (not echoed to terminal)
printf "Enter admin password: " && read -s PASSWORD && echo

# Generate htpasswd entry (user: admin)
HTPASSWD=$(htpasswd -nb admin "$PASSWORD")

# Create admin-auth secret in each namespace that needs it
for ns in longhorn monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic admin-auth -n "$ns" \
    --from-literal=auth="$HTPASSWD" \
    --from-literal=user=admin \
    --from-literal=password="$PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# Set ArgoCD admin password (bcrypt hash in argocd-secret)
HASH=$(htpasswd -nbBC 10 "" "$PASSWORD" | tr -d ':\n' | sed 's/$2y/$2a/')
kubectl -n argo-cd patch secret argocd-secret \
  -p "{\"stringData\": {\"admin.password\": \"$HASH\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"

echo "Admin password set for all services."
```

Restart the ArgoCD server to pick up the new password:

```bash
kubectl -n argo-cd rollout restart deployment argocd-server
```

### Updating the password later

Re-run the script above with a new password, then restart services that cache credentials:

```bash
kubectl -n argo-cd rollout restart deployment argocd-server
kubectl -n monitoring rollout restart statefulset grafana-prometheus
```

## Access Grafana

Once the `grafana-prometheus` ArgoCD app is synced:

### Via ingress

**https://grafana.your-domain.com** — login with `admin` and the shared admin password.

### Via port-forward

```bash
grafana.sh
# Or manually:
kubectl -n monitoring port-forward sts/grafana-prometheus 3000
# Open http://localhost:3000
```

Grafana comes preconfigured with the `kube-prometheus-stack` dashboards for cluster
monitoring (node metrics, pod resource usage, etc.).

## Access Longhorn UI

Once the `longhorn` ArgoCD app is synced:

### Via ingress

**https://longhorn.your-domain.com** — login with `admin` and the shared admin password
(basic-auth prompt).

### Via port-forward

```bash
longhorn.sh
```

The Longhorn UI shows storage volumes, replicas, and backup status.

## Access Headlamp (Kubernetes Dashboard)

Headlamp uses Kubernetes token authentication (not the shared admin password).

### Generate a login token

```bash
kubectl create token headlamp-admin -n headlamp --duration=24h
```

### Access the dashboard

Via ingress: **https://headlamp.your-domain.com**

Via port-forward:

```bash
dashboard.sh
# Or manually:
kubectl port-forward svc/headlamp -n headlamp 4466:80
# Open http://localhost:4466
```

Paste the token into the login screen.

## Access Open WebUI (LLM chat)

Open WebUI provides a ChatGPT-style interface backed by RKLLama running on the RK1
nodes' NPU. It is only useful once at least one model has been pulled — see
{doc}`rkllama-models`.

:::{note}
RKLLama and Open WebUI are only functional on clusters with **RK1 compute modules**.
The services will deploy on any cluster, but inference requires the Rockchip NPU.
:::

Via ingress: **https://open-webui.your-domain.com**

First-time access requires creating an account — the first account registered
automatically becomes the admin. Once logged in, select a model from the dropdown
(models appear within ~30 seconds of being pulled).

Via port-forward:

```bash
kubectl port-forward svc/open-webui -n open-webui 8080:80
# Open http://localhost:8080
```

## Access the echo test service

The echo service at **https://echo.your-domain.com** returns a JSON response with all
incoming request details — useful for verifying ingress, TLS, and headers are working
correctly.

:::{tip}
Install the [JSON Formatter](https://chromewebstore.google.com/detail/json-formatter/bcjindcccaagfpapjjmafapmmgkkhgoa)
Chrome extension to view the echo response pretty-printed in your browser.
:::

## Clean up the initial admin secret

After setting a permanent password, you can delete the auto-generated ArgoCD initial
admin secret:

```bash
kubectl -n argo-cd delete secret argocd-initial-admin-secret
```

## Next steps

- {doc}`cloudflare-tunnel` — expose services to the internet via Cloudflare
- {doc}`manage-sealed-secrets` — manage encrypted secrets in the repository
- {doc}`add-remove-services` — customise which services are deployed
- {doc}`rkllama-models` — pull LLM models for RKLLama (RK1 clusters only)
