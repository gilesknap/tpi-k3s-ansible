# Set Up OAuth Authentication

:::{seealso}
For a high-level overview of how authentication works across all services,
see {doc}`/explanations/authentication`.
:::

This guide walks through configuring both authentication paths used by the
cluster. Each path uses its own GitHub OAuth App:

- **Part A** — Dex OIDC, used by **ArgoCD, Grafana, and
  argocd-monitor** (services with native OIDC support).
- **Part B** — oauth2-proxy, used by **Headlamp, Alertmanager, the
  Minecraft dashboard and scrap** (admin-only services with no native OIDC).

## Prerequisites

- A working cluster with ingress-nginx and cert-manager
- A GitHub account (the OAuth provider)
- `kubeseal` installed locally (see {doc}`manage-sealed-secrets`)

---

## Part A: Dex OIDC setup

Dex runs inside the ArgoCD server pod and acts as a shared OIDC provider
for all services that support native OIDC login. It uses a GitHub OAuth App
as its upstream identity source.

### A1: Create a GitHub OAuth App for Dex

1. Go to [github.com/settings/developers](https://github.com/settings/developers).
2. Click **New OAuth App**.
3. Fill in the form:

| Field | Value |
|---|---|
| Application name | `k3s-dex` (or any name) |
| Homepage URL | `https://argocd.<your-domain>` |
| Authorization callback URL | `https://argocd.<your-domain>/api/dex/callback` |

4. Click **Register application**.
5. Copy the **Client ID**.
6. Click **Generate a new client secret** and copy it immediately.

### A2: Create the OAuth app for oauth2-proxy too

On a fresh cluster all the Dex and oauth2-proxy secrets are generated and
sealed together, so create the second GitHub OAuth App now as well, before
sealing (step {ref}`B1 <oauth-b1>`).

### A3: Generate and seal the secrets (first-time setup)

Export the external credentials, then run `just generate-and-seal-all`:

```bash
export GITHUB_CLIENT_ID=...            # Dex OAuth App (A1)
export GITHUB_CLIENT_SECRET=...
export OAUTH2_PROXY_CLIENT_ID=...      # oauth2-proxy OAuth App (B1)
export OAUTH2_PROXY_CLIENT_SECRET=...
export CLOUDFLARE_API_TOKEN=...        # see cloudflare-tunnel / cloudflare-as-code
export CLOUDFLARE_TUNNEL_TOKEN=...
just generate-and-seal-all
```

This generates and seals `argocd-dex-secret`, `grafana-oauth-secret`,
`argocd-monitor-oauth-secret` and `oauth2-proxy-credentials` together, along
with the other cluster secrets. The `argo-cd` Dex client secret is derived
from ArgoCD's `server.secretkey` automatically.

:::{warning}
`just generate-and-seal-all` regenerates **every** cluster secret. Use it only
on a fresh setup; on an established cluster, rotate individual secrets
instead (below).
:::

### A4: Rotate a single secret later

To rotate one Dex-related secret on a running cluster, use
`just seal-argocd-dex` with a subcommand:

```bash
just seal-argocd-dex github    # new GitHub OAuth Client ID/Secret
just seal-argocd-dex argocd    # re-derive the argo-cd client secret
just seal-argocd-dex monitor   # argocd-monitor client + cookie secrets
just seal-argocd-dex grafana   # grafana client secret
```

The subcommands read existing keys from the running `argocd-dex-secret`, so
it must already exist in the cluster.

### A5: Configure admin and viewer emails

Edit `kubernetes-services/values.yaml` and set the email lists:

```yaml
# Full admin access to all services
admin_emails:
  - alice@example.com
```

Also add `admin_emails` to `group_vars/all.yml` (required for
Ansible-rendered ArgoCD RBAC):

```yaml
admin_emails:
  - alice@example.com
```

:::{important}
`admin_emails` must be kept in sync between `values.yaml` and
`group_vars/all.yml`. After changing the latter, re-run
`ansible-playbook pb_all.yml --tags cluster`.
:::

### A6: Deploy

Commit and push all SealedSecrets. ArgoCD syncs automatically. After sync,
restart pods that read secrets from environment variables:

```bash
kubectl rollout restart statefulset/grafana-prometheus -n monitoring
just restart-dex   # Dex and argocd-server
```

### Adding a new Dex static client

To add a new service that authenticates via Dex:

1. Add a `staticClients` entry in the `dex.config` section of
   `roles/cluster/tasks/argocd.yml`, with the service's redirect URI and
   a reference to its secret key in `argocd-dex-secret`.
2. Re-seal `argocd-dex-secret` with the new client secret included (extend
   `scripts/seal-argocd-dex` with a subcommand for it, modelled on
   `just seal-argocd-dex grafana`).
3. Configure the service's OIDC settings to point at
   `https://argocd.<your-domain>/api/dex`.
4. Run `ansible-playbook pb_all.yml --tags cluster` to apply the updated
   Dex config, then commit and push the sealed secret.

---

## Part B: oauth2-proxy setup

oauth2-proxy is a lightweight reverse proxy that authenticates users
directly with GitHub. It protects services that lack native OIDC support.

(oauth-b1)=
### B1: Create a GitHub OAuth App for oauth2-proxy

1. Go to [github.com/settings/developers](https://github.com/settings/developers).
2. Click **New OAuth App**.
3. Fill in the form:

| Field | Value |
|---|---|
| Application name | `k3s-oauth2-proxy` (or any name) |
| Homepage URL | `https://oauth2.<your-domain>` |
| Authorization callback URL | `https://oauth2.<your-domain>/oauth2/callback` |

4. Click **Register application**.
5. Copy the **Client ID** and generate a **Client Secret**.

If you ran `just generate-and-seal-all` in A3, the oauth2-proxy credentials
are already sealed: skip to B4. B2 and B3 seal them by hand.

### B2: Generate a cookie secret

```bash
python3 -c 'import secrets; print(secrets.token_hex(16))'
```

This prints 32 characters; oauth2-proxy uses the cookie secret as raw bytes
and refuses to start unless it is 16, 24 or 32 bytes long.

### B3: Create and seal the credentials

```bash
printf 'GitHub Client ID: ' && read -r CLIENT_ID
printf 'GitHub Client Secret: ' && read -rs CLIENT_SECRET && echo
printf 'Cookie Secret: ' && read -rs COOKIE_SECRET && echo

kubectl create secret generic oauth2-proxy-credentials \
  --namespace oauth2-proxy \
  --from-literal=client-id="$CLIENT_ID" \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --from-literal=cookie-secret="$COOKIE_SECRET" \
  --dry-run=client -o yaml | \
kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
  kubernetes-services/additions/oauth2-proxy/oauth2-proxy-secret.yaml

unset CLIENT_ID CLIENT_SECRET COOKIE_SECRET
```

### B4: Add a DNS record

Add a grey-cloud (DNS-only) A record for the oauth2-proxy ingress:

| Type | Name | Content | Proxy status |
|------|------|---------|-------------|
| A | `oauth2` | `<worker-node-ip>` | DNS only |

### B5: Enable oauth2-proxy

In `kubernetes-services/values.yaml`:

```yaml
enable_oauth2_proxy: true
```

Commit and push. ArgoCD adds OAuth annotations to all protected ingresses.

### How oauth2-proxy is wired to services

Services use the shared ingress template at
`kubernetes-services/additions/ingress/templates/ingress.yaml`. To protect
a service, set `oauth2_proxy: true` in its ingress values:

```yaml
# In the ArgoCD Application template (e.g. dashboard.yaml)
helm:
  valuesObject:
    oauth2_proxy: true  # ← enables auth annotations
```

This adds nginx `auth-url` and `auth-signin` annotations that check with
oauth2-proxy before forwarding each request.

Services protected by oauth2-proxy (admin-only):

- **Headlamp** — uses OAuth as the outer access control layer
- **Alertmanager** — no app-level auth, so OAuth is the only gate
- **Minecraft dashboard** — when `enable_minecraft` is set
- **scrap** — the PWA; its `/mcp` ingress has no oauth2-proxy

---

## Integrating with Cloudflare Access

For services exposed via the Cloudflare tunnel, add a second
authentication layer using Cloudflare Access at zero cluster overhead.
Configure an Access Application in the Cloudflare Zero Trust dashboard
with an email allowlist covering everyone who should have access. See
{doc}`cloudflare-ssh-tunnel` for how Access Applications work.

## Troubleshooting

### Redirect loop after enabling OAuth

The oauth2-proxy ingress must **not** itself be protected by OAuth. Check
that `oauth2-proxy.yaml` does not set `oauth2_proxy: true` on its own
ingress values.

### 403 after GitHub login

For oauth2-proxy services (Headlamp, Alertmanager, the Minecraft dashboard,
scrap): the email must be
in `admin_emails` in `values.yaml`. Viewer users cannot access these services
by design.

For Dex-authenticated services: any GitHub user can log in. A 403 likely
means the service has additional access restrictions.

### Cookie domain mismatch

The `cookie-domain` must match your cluster domain (e.g. `.<your-domain>`).
All protected services must be subdomains of this domain.

### OAuth not enforced (service loads without login)

Verify the ingress annotations are present:

```bash
kubectl get ingress -n <namespace> <service>-ingress -o yaml | grep auth
```

You should see `auth-url` and `auth-signin` annotations.

### Dex login returns 404

Ensure the OIDC discovery URL includes the full path:
`https://argocd.<your-domain>/api/dex/.well-known/openid-configuration`.
The base path `/api/dex` redirects to `/api/dex/` which returns 404 —
some OIDC libraries do not follow this redirect.

### Dex rejects redirect URI

Cloudflare Tunnel services may generate `http://` callback URIs. Add both
`http://` and `https://` redirect URIs to the Dex static client
configuration.
