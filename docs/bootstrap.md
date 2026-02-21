# Bootstrapping the Cluster

This document covers what to do after running `ansible-playbook pb_all.yml` for the first time, and how to access cluster services before DNS is fully functional.

## Network Prerequisites

The cluster relies on your router assigning stable DHCP addresses to each node by MAC address. The expected layout something along these lines:

| IP             | Host     | Role                        |
|----------------|----------|-----------------------------|
| 192.168.1.80   | turingpi | Turing Pi BMC               |
| 192.168.1.81   | node01   | K3s control plane           |
| 192.168.1.82   | node02   | K3s worker                  |
| 192.168.1.83   | node03   | K3s worker                  |
| 192.168.1.84   | node04   | K3s worker                  |

DNS entries for all cluster services (e.g. `argocd.gkcluster.org`, `headlamp.gkcluster.org`) must point to **one or more of the worker nodes** (192.168.1.82 / 192.168.1.83 / 192.168.1.84) — **not** the control plane (192.168.1.81). The ingress-nginx LoadBalancer runs on the workers, not the control plane. You can add up to three A records for the same wildcard hostname for basic round-robin:

```
*.gkcluster.org  A  192.168.1.82
*.gkcluster.org  A  192.168.1.83
*.gkcluster.org  A  192.168.1.84
```

Alternatively a single worker IP is sufficient — kube-proxy routes traffic to the ingress pod regardless of which worker receives it.

## Step 1: Run the Playbook

```bash
ansible-playbook pb_all.yml
```

Or in stages:
```bash
ansible-playbook pb_all.yml --tags tools      # install helm, kubectl etc. in devcontainer
ansible-playbook pb_all.yml --tags k3s        # install K3s on nodes
ansible-playbook pb_all.yml --tags cluster    # deploy ArgoCD and bootstrap the cluster
```

After `--tags cluster` completes, ArgoCD is installed and will begin syncing all services defined in `kubernetes-services/`. This takes a few minutes.

## Step 2: Access the ArgoCD UI

### Via port-forward (before DNS is working)

```bash
kubectl port-forward svc/argocd-server -n argo-cd 8080:443
```

Then open **https://localhost:8080** in your browser (accept the self-signed certificate warning).

Get the initial admin password:
```bash
kubectl -n argo-cd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Login with username `admin` and the password above.

### Via ingress (once DNS is working)

Once your DNS entries resolve `argocd.gkcluster.org` → a worker node IP (e.g. `192.168.1.82`), you can access ArgoCD at **https://argocd.gkcluster.org** directly.

## Step 3: Watch ArgoCD Sync

After logging in, you should see the `all-cluster-services` app-of-apps and its child applications. They will sync automatically — allow a few minutes for all services to reach `Synced / Healthy`.

Services that require `OutOfSync` attention can be manually synced from the UI or via:
```bash
kubectl patch application all-cluster-services -n argo-cd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Step 4: Set Up Shared Admin Password

Several cluster services share a common admin password via a Kubernetes secret
called `admin-auth`. This secret must be created **before** the services that
depend on it are synced by ArgoCD. ArgoCD does not manage this secret — it is
created manually and persists across syncs.

The secret is used by:

| Service   | How                                              |
|-----------|--------------------------------------------------|
| ArgoCD    | Admin password set via `argocd-secret` patch     |
| Grafana   | `admin.existingSecret` references `admin-auth`   |
| Longhorn  | Nginx basic-auth on ingress                      |
| Headlamp  | Nginx basic-auth on ingress                      |

RKLlama and Echo are intentionally left without authentication.

### Create the secrets

```bash
# Prompt for password (not echoed to terminal)
printf "Enter admin password: " && read -s PASSWORD && echo

# Generate htpasswd entry (user: admin)
HTPASSWD=$(htpasswd -nb admin "$PASSWORD")

# Create admin-auth secret in each namespace that needs it.
# The secret contains both htpasswd (for nginx basic-auth) and plain text
# password (for Grafana's existingSecret).
for ns in longhorn monitoring headlamp; do
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

After running this, **restart the ArgoCD server** so it picks up the new password:
```bash
kubectl -n argo-cd rollout restart deployment argocd-server
```

### Updating the password later

Re-run the same script above with a new `PASSWORD` value. Then restart any
services that cache credentials:
```bash
kubectl -n argo-cd rollout restart deployment argocd-server
kubectl -n monitoring rollout restart statefulset grafana-prometheus
```

## Step 5: Access the Kubernetes Dashboard (Headlamp)

Once the `headlamp` ArgoCD app is `Synced / Healthy`, the `headlamp` namespace will exist.

Headlamp is protected by nginx basic-auth using the shared admin password
(see Step 4). After basic-auth, Headlamp also requires a Kubernetes token
on first login.

Generate a login token using the `headlamp-admin` service account (cluster-admin rights):
```bash
kubectl create token headlamp-admin -n headlamp --duration=24h
```

Access Headlamp at **https://headlamp.gkcluster.org** (once DNS resolves), or via port-forward:
```bash
kubectl port-forward svc/headlamp -n headlamp 4466:80
# then open http://localhost:4466
```

Paste the token into the Headlamp login screen.

## Notes

- ArgoCD must be pointed at the correct branch. If working on a non-main branch, pass `-e repo_branch=<branch>` when running the playbook so ArgoCD tracks the right branch.
- The initial admin secret can be deleted after you have set a permanent password: `kubectl -n argo-cd delete secret argocd-initial-admin-secret`
