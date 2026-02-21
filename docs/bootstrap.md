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

DNS entries for all cluster services (e.g. `argocd.gkcluster.org`, `headlamp.gkcluster.org`) should point to **192.168.1.81** (node01, the control plane, where ingress-nginx runs).

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

Once your DNS entries resolve `argocd.gkcluster.org` → `192.168.1.81`, you can access ArgoCD at **https://argocd.gkcluster.org** directly.

## Step 3: Watch ArgoCD Sync

After logging in, you should see the `all-cluster-services` app-of-apps and its child applications. They will sync automatically — allow a few minutes for all services to reach `Synced / Healthy`.

Services that require `OutOfSync` attention can be manually synced from the UI or via:
```bash
kubectl patch application all-cluster-services -n argo-cd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Step 4: Access the Kubernetes Dashboard (Headlamp)

Once the `headlamp` ArgoCD app is `Synced / Healthy`, the `headlamp` namespace will exist.

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
