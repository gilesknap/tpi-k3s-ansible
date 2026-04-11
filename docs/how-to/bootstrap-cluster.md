# Bootstrap the Cluster

After the Ansible playbook completes, ArgoCD is installed and will begin syncing
all services. Follow these steps to finish the setup.

## Set Up the Shared Admin Password

Several services share a common admin password via a Kubernetes secret called
`admin-auth`. This secret is **not managed by ArgoCD** — it is created manually.

| Service | How it uses `admin-auth` |
|---------|-------------------------|
| ArgoCD | Admin password via `argocd-secret` patch |
| Grafana | `admin.existingSecret` references `admin-auth` |

The quickest way to set the password is with the Justfile target:

```bash
just set-admin-password
```

This prompts for a password (or reads ``ADMIN_PASSWORD`` from the environment),
creates the ``admin-auth`` secret in the ``monitoring`` namespace (used by
Grafana), patches the ArgoCD admin password, and restarts the ArgoCD server.

To update the password later, re-run the same command and restart cached
services:

```bash
just set-admin-password
kubectl -n monitoring rollout restart statefulset grafana-prometheus
```

## Verify ArgoCD Sync

Access ArgoCD via port-forward to check that all services are deploying:

```bash
kubectl port-forward svc/argocd-server -n argo-cd 8080:8080
```

Login with `admin` and the password you just set. You should see
`all-cluster-services` and its child applications. Allow a few minutes for all
services to reach `Synced / Healthy`.

If any applications are stuck, force a refresh:

```bash
kubectl patch application all-cluster-services -n argo-cd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Verify Headlamp OIDC Login

Headlamp authenticates via Dex (GitHub SSO). After ArgoCD syncs, visit
``https://headlamp.<your-domain>`` and click **Sign in**. You will be
redirected to GitHub via Dex. Admin emails get ``cluster-admin`` access;
viewer emails get read-only ``view`` access.

:::{note}
Headlamp OIDC requires the K3s API server to be configured with OIDC
flags. The Ansible ``k3s`` role deploys these automatically via
``/etc/rancher/k3s/config.yaml``. If you see token validation errors,
verify the config is deployed and k3s has been restarted.
:::

## Clean Up the Initial Admin Secret

After verifying everything works, delete the auto-generated secret:

```bash
kubectl -n argo-cd delete secret argocd-initial-admin-secret
```

## Next Steps

At this point your cluster is running and all services are accessible via
port-forward (see {doc}`accessing-services` for commands).

For DNS-based ingress with TLS certificates, continue to
{doc}`cloudflare-tunnel` — this sets up your domain, Let's Encrypt
certificates, and optionally exposes services to the internet.

Other guides:

- {doc}`manage-sealed-secrets` — manage encrypted secrets in the repository
- {doc}`add-remove-services` — customise which services are deployed
- {doc}`rkllama-models` — pull LLM models for RKLLama (RK1 clusters only)
