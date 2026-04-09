# ArgoCD Dex GitHub OAuth Setup

## Create the GitHub OAuth App

1. Go to https://github.com/settings/developers -> "New OAuth App"
2. Set:
   - **Application name**: ArgoCD (gkcluster)
   - **Homepage URL**: `https://argocd.gkcluster.org`
   - **Authorization callback URL**: `https://argocd.gkcluster.org/api/dex/callback`
3. Note the **Client ID** and generate a **Client Secret**

## Create and seal the secret

```bash
just seal-argocd-dex
```

Or manually:

```bash
kubectl create secret generic argocd-dex-secret \
  --namespace argo-cd \
  --from-literal=dex.github.clientID=<YOUR_CLIENT_ID> \
  --from-literal=dex.github.clientSecret=<YOUR_CLIENT_SECRET> \
  --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml \
  > kubernetes-services/additions/argocd/argocd-dex-secret.yaml
```

The `app.kubernetes.io/part-of: argocd` label is added automatically by the
just recipe. ArgoCD's Dex resolves `$var` references from secrets with this
label.

The sealed secret file must match `*-secret.yaml` for the `.gitleaks.toml` allowlist.

## Apply

Run the Ansible playbook with the `cluster` tag to apply the ConfigMap changes
and deploy the sealed secret:

```bash
ansible-playbook pb_all.yml --tags cluster
```

## Dex cross-client auth for argocd-monitor

argocd-monitor authenticates users via an oauth2-proxy sidecar that talks to
ArgoCD's built-in Dex server. It uses Dex cross-client auth to get tokens with
the `argo-cd` audience so ArgoCD's API accepts them.

### How it works

ArgoCD auto-generates Dex static clients (`argo-cd`, `argo-cd-cli`,
`argo-cd-pkce`) at the start of the client list. Custom clients from
`dex.config` in `argocd-cm` are appended **after** them. When duplicate client
IDs exist, the **first entry wins** — DEX v2.45+ memory storage rejects
duplicates with `ErrAlreadyExists` and keeps the original.

We declare an `argo-cd` client in `dex.config` with
`trustedPeers: [argocd-monitor]`, but because the auto-generated `argo-cd`
entry (without `trustedPeers`) is stored first, our override is silently
dropped. As a result, DEX shows a "Grant Access" approval screen for
argocd-monitor's cross-client auth flow. This is cosmetic (one extra click)
and cannot be fixed without upstream ArgoCD changes to either suppress
auto-generated clients or support `trustedPeers` on them.

The `argocd-monitor` oauth2-proxy requests scope
`audience:server:client_id:argo-cd`, so the Dex token has the `argo-cd`
audience that ArgoCD accepts.

### Why not `server.additional.audiences`?

ArgoCD with Dex **hardcodes** allowed audiences to `argo-cd` and `argo-cd-cli`
in `OAuth2AllowedAudiences()`. The `server.additional.audiences` key in
`argocd-cmd-params-cm` is only used with external OIDC providers (not Dex).
Setting `allowedAudiences` in `oidc.config` is also not viable because having
`oidc.config` present causes `IsDexDisabled()` to return true.

### Client secret derivation

The `argo-cd` client secret is derived from ArgoCD's `server.secretkey`:

```
SHA256(server.secretkey string)[:30 bytes] → base64url (no padding)
```

The `just seal-argocd-dex` recipe computes this automatically.

## Dex as shared OIDC provider

Dex also serves as the OIDC provider for other cluster services, removing
the need for separate GitHub OAuth Apps or oauth2-proxy on those services.

| Static Client | Service | Auth Method |
|---------------|---------|-------------|
| `argo-cd` | ArgoCD | Built-in Dex integration |
| `argocd-monitor` | argocd-monitor | oauth2-proxy sidecar |
| `grafana` | Grafana | `auth.generic_oauth` in `grafana.ini` |
| `open-webui` | Open WebUI | `OPENID_PROVIDER_URL` env var |
| `headlamp` | Headlamp | Active — native OIDC via K3s API server OIDC flags |

Each service has its own SealedSecret containing the client secret.
The Dex secret (`argocd-dex-secret`) holds all client secrets referenced
by `$argocd-dex-secret:<key>` in `argocd-cm`.
