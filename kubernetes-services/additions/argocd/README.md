# ArgoCD configuration

This directory contains ArgoCD post-bootstrap configuration managed by the
`argocd-config` Application.

## Files

- `argocd-cm.yml` — ConfigMap with Dex OIDC config and custom health checks
- `argocd-rbac-cm.yml` — RBAC policy mapping GitHub emails to ArgoCD roles
- `argocd-dex-secret.yaml` — SealedSecret with GitHub OAuth App credentials for Dex

## Create the Dex credentials secret

1. Create a GitHub OAuth App at https://github.com/settings/developers
   - Homepage URL: `https://argocd.<your-domain>`
   - Callback URL: `https://argocd.<your-domain>/api/dex/callback`

2. Patch the existing `argocd-secret` with the Dex credentials and seal it:
   ```bash
   kubectl get secret argocd-secret -n argo-cd -o yaml | \
   kubectl patch --local -f - --type=json -p='[
     {"op":"add","path":"/data/dex.github.clientID","value":"'$(echo -n YOUR_GITHUB_CLIENT_ID | base64)'"},
     {"op":"add","path":"/data/dex.github.clientSecret","value":"'$(echo -n YOUR_GITHUB_CLIENT_SECRET | base64)'"}
   ]' -o yaml | \
   kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
     argocd-dex-secret.yaml
   ```

   Alternatively, create a standalone secret that ArgoCD will merge:
   ```bash
   kubectl create secret generic argocd-dex-credentials \
     --namespace argo-cd \
     --from-literal=dex.github.clientID=YOUR_GITHUB_CLIENT_ID \
     --from-literal=dex.github.clientSecret=YOUR_GITHUB_CLIENT_SECRET \
     --dry-run=client -o yaml | \
   kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
     argocd-dex-secret.yaml
   ```

   Note: The `$dex.github.clientID` syntax in `argocd-cm.yml` references keys
   from the `argocd-secret` Secret. If using a separate secret, you must add the
   label `app.kubernetes.io/part-of: argocd` to it.

3. Commit and push the SealedSecret file.
