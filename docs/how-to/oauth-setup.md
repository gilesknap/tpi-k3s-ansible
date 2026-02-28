# Set Up OAuth Authentication

This guide walks through securing cluster services with
[oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) and GitHub
as the OIDC provider.

## Architecture

```
Browser → ingress-nginx → oauth2-proxy (auth check) → backend service
                ↕
         GitHub OAuth (OIDC login)
```

oauth2-proxy acts as an authentication middleware. When a user visits a
protected service, nginx checks with oauth2-proxy before forwarding the
request. If the user is not authenticated, they are redirected to GitHub
to log in.

**Why oauth2-proxy?** Authentik and Keycloak each need ~2 GB of RAM — too
heavy for a small ARM cluster. oauth2-proxy uses ~128 Mi and integrates
directly with the existing ingress-nginx annotations.

## Prerequisites

- A working cluster with ingress-nginx and cert-manager
- A GitHub account (the OAuth provider)
- `kubeseal` installed locally (see {doc}`manage-sealed-secrets`)
- The `oauth2-proxy` namespace must exist (ArgoCD creates it automatically
  via `CreateNamespace=true`)

## Step 1: Create a GitHub OAuth App

1. Go to [github.com/settings/developers](https://github.com/settings/developers).
2. Click **New OAuth App**.
3. Fill in the form:

| Field | Value |
|---|---|
| Application name | `k3s-cluster` (or any name) |
| Homepage URL | `https://oauth2.<your-domain>` |
| Authorization callback URL | `https://oauth2.<your-domain>/oauth2/callback` |

4. Click **Register application**.
5. Copy the **Client ID**.
6. Click **Generate a new client secret** and copy it immediately.

## Step 2: Generate a cookie secret

```bash
python3 -c 'import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
```

## Step 3: Create and seal the credentials

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

Commit and push:

```bash
git add kubernetes-services/additions/oauth2-proxy/oauth2-proxy-secret.yaml
git commit -m "Add oauth2-proxy credentials SealedSecret"
git push
```

## Step 4: Add a DNS record

Add a grey-cloud (DNS-only) A record in the Cloudflare dashboard for the
oauth2-proxy ingress:

| Type | Name | Content | Proxy status |
|------|------|---------|-------------|
| A | `oauth2` | `192.168.1.82` | DNS only |

Use one of your worker node IPs. This is the same pattern as other LAN-only
services (see {doc}`cloudflare-tunnel` Part 3).

## Step 5: Deploy oauth2-proxy

oauth2-proxy is deployed as an ArgoCD Application defined in
`kubernetes-services/templates/oauth2-proxy.yaml`. After pushing the
SealedSecret, ArgoCD syncs automatically.

Verify the deployment:

```bash
kubectl rollout status deployment/oauth2-proxy -n oauth2-proxy
kubectl get ingress -n oauth2-proxy
```

Visit `https://oauth2.<your-domain>` — you should see a GitHub login page.

## Step 6: Enable the OAuth toggle

Now that oauth2-proxy is running, enable it for all protected services by editing
`kubernetes-services/values.yaml`:

```yaml
enable_oauth2_proxy: true
```

Commit and push:

```bash
git add kubernetes-services/values.yaml
git commit -m "Enable OAuth2 proxy for cluster services"
git push
```

ArgoCD will pick up the change and add OAuth annotations to all protected ingresses.

## Step 7: How OAuth is wired to services

Services use the shared ingress template at
`kubernetes-services/additions/ingress/templates/ingress.yaml`. To protect
a service with OAuth, set `oauth2_proxy: true` in its ingress values:

```yaml
# In the ArgoCD Application template (e.g. dashboard.yaml)
helm:
  valuesObject:
    name: headlamp
    cluster_domain: example.com
    service_name: headlamp
    service_port: 80
    oauth2_proxy: true  # ← enables OAuth
```

This adds nginx auth annotations that redirect unauthenticated requests
to oauth2-proxy.

Services currently protected by OAuth:

- Grafana (`grafana.yaml`) — native login after OAuth gateway
- Longhorn (`longhorn.yaml`) — no native auth, OAuth is the only layer
- Headlamp (`dashboard.yaml`) — requires a service account token after OAuth
- Open WebUI (`open-webui.yaml`) — native login after OAuth gateway
- ArgoCD (`argo-cd/ingress.yaml`) — uses TLS passthrough with its own login
  (managed by Ansible, not the shared ingress template)

## Step 8: Restrict access (optional)

To restrict access to members of a specific GitHub organisation, add the
`github-org` flag in `kubernetes-services/templates/oauth2-proxy.yaml`:

```yaml
extraArgs:
  github-org: "your-org-name"
```

To restrict to specific email addresses, replace `email-domain: "*"` with
a comma-separated list of allowed emails.

## Integrating with Cloudflare Access

For services exposed via the Cloudflare tunnel (e.g. Open WebUI), you can
add a second authentication layer using Cloudflare Access at zero cluster
overhead. See {doc}`cloudflare-ssh-tunnel` for how Access Applications
work, and apply the same pattern to any tunnelled service.

## Troubleshooting

### Redirect loop after enabling OAuth

The oauth2-proxy ingress must **not** itself be protected by OAuth. Check
that `oauth2-proxy.yaml` does not set `oauth2_proxy: true` on its own
ingress values.

### 403 after GitHub login

Check the `email-domain` or `github-org` restrictions in the oauth2-proxy
configuration. Verify that the authenticated email matches the allowed
list.

### Cookie domain mismatch

The `cookie-domain` must match your cluster domain (e.g. `.gkcluster.org`).
All protected services must be subdomains of this domain.

### OAuth not enforced (service loads without login)

Verify the ingress annotations are present:

```bash
kubectl get ingress -n <namespace> <service>-ingress -o yaml | grep auth
```

You should see `auth-url` and `auth-signin` annotations pointing to
`oauth2.<your-domain>`.
