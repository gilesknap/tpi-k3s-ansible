# Bootstrap the Cluster

After the Ansible playbook completes, ArgoCD is installed and will begin syncing
all services. Follow these steps to finish the setup.

:::{tip}
**NAS prerequisite for backups.** The daily and weekly backup CronJobs write
to an NFS export on a NAS. If you intend to run backups (recommended for any
stateful workload — Grafana, Jellyfin), set up the
NAS share **before** the first backup runs. See {doc}`nas-setup` — this is a
one-time manual runbook on the NAS itself.
:::

## Set Up the Shared Admin Password

Grafana's built-in admin account reads its password from a Kubernetes secret
called `admin-auth` (via `admin.existingSecret`). This secret is **not managed
by ArgoCD** — it is created manually. ArgoCD does not use it: the ArgoCD
local admin account is disabled and all logins go through Dex (GitHub).

The quickest way to set the password is with the Justfile target:

```bash
just set-admin-password
```

This prompts for a password (or reads ``ADMIN_PASSWORD`` from the environment)
and creates the ``admin-auth`` secret in the ``monitoring`` namespace (used by
Grafana).

Grafana reads this password only when it first creates its database, so
re-running `just set-admin-password` later does not change the password of a
running Grafana. To rotate it, update the secret and reset it in Grafana too:

```bash
just set-admin-password
kubectl -n monitoring exec statefulset/grafana-prometheus -c grafana -- \
  grafana cli admin reset-admin-password '<new-password>'
```

## Verify ArgoCD Sync

Check that all services are deploying with a read-only query:

```bash
kubectl get applications -n argo-cd
```

You should see `all-cluster-services` and its child applications. Allow a few
minutes for all services to reach `Synced / Healthy`.

The ArgoCD web UI has no local admin account: it signs in through Dex
(GitHub), which needs the sealed OAuth credentials from {doc}`oauth-setup` and
redirects back to `https://argocd.<domain>`. Until that is set up, use
`kubectl` instead of the UI (or `argocd app list --core`, with the current
kubeconfig context's namespace set to `argo-cd`).

If any applications are stuck, force a refresh:

```bash
kubectl patch application all-cluster-services -n argo-cd \
  --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Verify Headlamp Login

With ``enable_oauth2_proxy: true``, Headlamp sits behind the cluster-wide
oauth2-proxy. After ArgoCD syncs, visit ``https://headlamp.<your-domain>`` and
pass the GitHub oauth2-proxy gate (only emails in ``admin_emails`` are let
through); with it ``false`` there is no gate in front of Headlamp. Headlamp
then asks for a token:
paste one from

```bash
just headlamp-token
# or: kubectl create token headlamp -n headlamp
```

## Next Steps

At this point your cluster is running and all services are accessible via
port-forward (see {doc}`accessing-services` for commands).

For DNS-based ingress with TLS certificates, continue to
{doc}`cloudflare-tunnel` — this sets up your domain, Let's Encrypt
certificates, and optionally exposes services to the internet.

Other guides:

- {doc}`../reference/services` — pick which services your cluster should run
  (quick-start configurations: monitoring, Minecraft, full stack)
- {doc}`manage-sealed-secrets` — manage encrypted secrets in the repository
- {doc}`add-remove-services` — customise which services are deployed
- {doc}`nas-setup` — create the NFS share layout used by backup CronJobs
  (one-time manual runbook on the NAS)
- {doc}`backup-restore` — verify backup CronJobs and restore from a dump
- {doc}`alternative-storage` — swap the static `local-nvme` default for
  another CSI driver (Longhorn, Rook-Ceph, …)
