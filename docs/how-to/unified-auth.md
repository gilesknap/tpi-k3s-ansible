# Set Up Unified Authentication and Authorisation

This guide extends the basic {doc}`oauth-setup` with native OIDC integration,
so your GitHub identity flows into each service's role-based access control
(RBAC). After completing this guide, users authenticate once via GitHub and
receive appropriate permissions across all services.

See {doc}`../explanations/decisions/0001-unified-auth-framework` for the
architectural rationale.

## Architecture

```
Browser → Cloudflare Access (TFA) → Cloudflare Tunnel
       → ingress-nginx → oauth2-proxy (auth check) → backend service
                                                         ↕
                                                    Native OIDC login
                                                    (GitHub → RBAC)
```

Three authentication layers work together:

1. **Cloudflare Access** — perimeter defence at the tunnel edge (email-based
   two-factor challenge).
2. **oauth2-proxy** — ingress-level gateway using GitHub OAuth. Blocks
   unauthenticated requests and passes identity headers to backends.
3. **Native OIDC** — services that support it (Grafana, ArgoCD, Open WebUI)
   authenticate directly with GitHub for SSO and RBAC role mapping.

## Prerequisites

- A working cluster with {doc}`oauth-setup` completed
- {doc}`cloudflare-web-tunnel` set up (optional but recommended)
- GitHub OAuth App credentials (from the oauth-setup guide)

## Per-service configuration

### ArgoCD — Dex with GitHub

ArgoCD uses its built-in Dex server to bridge GitHub OAuth (GitHub is not a
native OIDC provider). This gives ArgoCD a "Login via GitHub" button and maps
GitHub emails to ArgoCD RBAC roles.

**Step 1:** Create a GitHub OAuth App for ArgoCD:

| Field | Value |
|---|---|
| Application name | `argocd-dex` |
| Homepage URL | `https://argocd.<your-domain>` |
| Callback URL | `https://argocd.<your-domain>/api/dex/callback` |

**Step 2:** Seal the Dex credentials:

```bash
kubectl create secret generic argocd-dex-credentials \
  --namespace argo-cd \
  --from-literal=dex.github.clientID="$CLIENT_ID" \
  --from-literal=dex.github.clientSecret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | \
kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
  kubernetes-services/additions/argocd/argocd-dex-secret.yaml
```

**Step 3:** Edit RBAC in ``kubernetes-services/additions/argocd/argocd-rbac-cm.yml``:

```yaml
policy.csv: |
  g, admin@example.com, role:admin
  g, viewer@example.com, role:readonly
policy.default: role:readonly
```

**Step 4:** Commit and push. ArgoCD syncs the config automatically.

**Step 5:** Add ArgoCD to the Cloudflare tunnel in the Zero Trust dashboard:

| Public hostname | Service |
|---|---|
| `argocd.<your-domain>` | `http://argocd-server.argo-cd.svc.cluster.local:80` |

### Grafana — Generic OAuth

Grafana authenticates directly with GitHub and maps emails to Grafana roles
(Admin, Editor, Viewer).

**Step 1:** Create a GitHub OAuth App for Grafana:

| Field | Value |
|---|---|
| Application name | `grafana-oauth` |
| Homepage URL | `https://grafana.<your-domain>` |
| Callback URL | `https://grafana.<your-domain>/login/generic_oauth` |

**Step 2:** Seal the credentials:

```bash
kubectl create secret generic grafana-oauth \
  --namespace monitoring \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_ID="$CLIENT_ID" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="$CLIENT_SECRET" \
  --dry-run=client -o yaml | \
kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
  kubernetes-services/additions/grafana/grafana-oauth-secret.yaml
```

**Step 3:** Edit admin emails in ``kubernetes-services/values.yaml``:

```yaml
grafana_admin_emails:
  - admin@example.com
```

Users on this list get the Grafana Admin role. Everyone else who authenticates
via GitHub gets Viewer.

**Step 4:** Commit and push.

### Open WebUI — Trusted Header Auth

Open WebUI uses the ``X-Auth-Request-Email`` header from oauth2-proxy to
auto-create user accounts. No additional OAuth App is needed.

This is configured automatically via the ``WEBUI_AUTH_TRUSTED_EMAIL_HEADER``
environment variable in the Open WebUI deployment. The first user to access
Open WebUI becomes admin.

### Headlamp — Token Login

Headlamp does not support OIDC or proxy auth headers. It uses a service
account token for login. oauth2-proxy provides the authentication gateway;
the token controls Kubernetes RBAC.

The ``headlamp-dashboard`` ClusterRole provides read access to all resources
and write access to common workload resources (pods, deployments, services,
etc.).

### Longhorn — OAuth Gateway Only

Longhorn has no native authentication. oauth2-proxy is the sole access
control layer. Longhorn is not exposed via the Cloudflare tunnel.

## Managing users

All user access is controlled by editing ``kubernetes-services/values.yaml``
and pushing to git:

| Setting | Controls |
|---|---|
| ``oauth2_emails`` | Who can pass the oauth2-proxy gateway |
| ``argocd_admin_emails`` | Who gets ArgoCD admin role |
| ``grafana_admin_emails`` | Who gets Grafana Admin role |

For ArgoCD RBAC beyond admin/readonly, edit
``kubernetes-services/additions/argocd/argocd-rbac-cm.yml`` directly.

## Disabling unified auth

To revert to basic oauth2-proxy gateway auth (no native OIDC):

1. Remove the ``grafana.ini`` OAuth section from ``grafana.yaml``
2. Comment out ``dex.config`` in ``argocd-cm.yml``
3. Remove the ``WEBUI_AUTH_TRUSTED_EMAIL_HEADER`` env var from ``open-webui.yaml``
4. Commit and push — services fall back to their native login pages behind
   the oauth2-proxy gateway.

## Troubleshooting

### ArgoCD shows "Login" but Dex fails

Check that the SealedSecret has been unsealed:

```bash
kubectl get secret argocd-dex-credentials -n argo-cd
```

Check Dex logs:

```bash
kubectl logs -n argo-cd deployment/argocd-dex-server
```

### Grafana "Login with GitHub" returns 500

Verify the OAuth secret exists and has the correct keys:

```bash
kubectl get secret grafana-oauth -n monitoring -o jsonpath='{.data}' | jq 'keys'
```

Expected keys: ``GF_AUTH_GENERIC_OAUTH_CLIENT_ID``,
``GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET``.

### Open WebUI does not auto-login

Verify the header is being passed by oauth2-proxy:

```bash
kubectl get ingress -n open-webui open-webui-ingress -o yaml | grep auth-response
```

The ``auth-response-headers`` annotation must include ``X-Auth-Request-Email``.
