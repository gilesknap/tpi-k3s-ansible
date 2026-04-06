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
