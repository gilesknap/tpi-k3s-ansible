# Bootstrap the Cluster

After the Ansible playbook completes, ArgoCD is installed and will begin syncing
all services. Follow these steps to finish the setup.

## Local Network Setup

These steps configure your **home router** to give the cluster stable IP
addresses and DNS names on your LAN.

### Fixed DHCP Leases

In your router's DHCP settings, assign **fixed leases** (also called "static leases"
or "address reservations") to each cluster node. This ensures nodes always receive
the same IP address after a reboot — without fixed leases, your DNS records could
become stale.

Find your nodes' MAC addresses with `ip link` or `arp -a`, then map each one to a
static IP in your router's admin interface (e.g. `192.168.1.82`, `.83`, `.84`).

:::{tip}
At commissioning time, the nodes will have been given names `node01`, `node02`, etc,
using mDNS. You can use these names to identify them in your router.
:::

### DNS Records

Each service with an ingress needs a DNS A record pointing to your **worker node IPs**
(not the control plane). For single-node clusters, point to that node's IP.

| DNS Name | Service |
|----------|---------|
| `argocd.<domain>` | ArgoCD |
| `grafana.<domain>` | Grafana |
| `longhorn.<domain>` | Longhorn UI |
| `headlamp.<domain>` | Headlamp dashboard |
| `rkllama.<domain>` | RKLlama LLM server |
| `open-webui.<domain>` | Open WebUI chat |

For high availability, create **one A record per worker node** for each hostname.

:::{tip}
If your router supports wildcard records, a single `*.<domain>` entry per worker
is much simpler:

```
*.<domain>  A  192.168.1.82
*.<domain>  A  192.168.1.83
*.<domain>  A  192.168.1.84
```
:::

## Set Up the Shared Admin Password

Several services share a common admin password via a Kubernetes secret called
`admin-auth`. This secret is **not managed by ArgoCD** — it is created manually.

| Service | How it uses `admin-auth` |
|---------|-------------------------|
| ArgoCD | Admin password via `argocd-secret` patch |
| Grafana | `admin.existingSecret` references `admin-auth` |
| Longhorn | nginx basic-auth on ingress |

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

# Restart ArgoCD to pick up the new password
kubectl -n argo-cd rollout restart deployment argocd-server

echo "Admin password set for all services."
```

To update the password later, re-run the script above and restart cached services:

```bash
kubectl -n argo-cd rollout restart deployment argocd-server
kubectl -n monitoring rollout restart statefulset grafana-prometheus
```

## Verify ArgoCD Sync

Access ArgoCD via port-forward to check that all services are deploying:

```bash
argo.sh
# Or manually:
kubectl port-forward svc/argocd-server -n argo-cd 8080:443
```

Login with `admin` and the password you just set. You should see
`all-cluster-services` and its child applications. Allow a few minutes for all
services to reach `Synced / Healthy`.

If any applications are stuck, force a refresh:

```bash
kubectl patch application all-cluster-services -n argo-cd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Clean Up the Initial Admin Secret

After verifying everything works, delete the auto-generated secret:

```bash
kubectl -n argo-cd delete secret argocd-initial-admin-secret
```

## Next Steps

- {doc}`accessing-services` — connect to each service via ingress or port-forward
- {doc}`cloudflare-tunnel` — expose services to the internet via Cloudflare
- {doc}`manage-sealed-secrets` — manage encrypted secrets in the repository
- {doc}`add-remove-services` — customise which services are deployed
- {doc}`rkllama-models` — pull LLM models for RKLLama (RK1 clusters only)
