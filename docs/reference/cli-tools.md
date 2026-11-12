# CLI Tools Reference

Tools installed by the `tools` role into the devcontainer.

## Installed binaries

### kubectl

Kubernetes CLI. Installed to `/usr/local/bin/kubectl` with bash and zsh completions.

```bash
# A 'k' alias is configured in .bashrc / .zshrc
k get pods -A
k logs -n argo-cd deploy/argocd-server
```

### helm

Helm package manager. Installed to `/usr/local/bin/helm` with bash and zsh
completions. Used by the `cluster` role to deploy ArgoCD and by ArgoCD for all
child app charts.

```bash
helm repo list
helm list -A
helm search repo ingress-nginx/ingress-nginx --versions
```

### kubeseal

CLI for Bitnami Sealed Secrets. Installed to `/usr/local/bin/kubeseal`. Used to
encrypt Kubernetes Secrets into SealedSecrets that are safe to commit to Git.

```bash
# Encrypt a secret
kubeseal --format yaml < secret.yaml > sealed-secret.yaml

# Fetch the public key
kubeseal --fetch-cert > pub-cert.pem
```

See {doc}`/how-to/manage-sealed-secrets` for the full workflow.

### argocd

ArgoCD CLI (pinned version). Installed to `$BIN_DIR` and linked into
`/usr/local/bin/argocd`.

```bash
# core mode uses the current kubeconfig context's namespace
kubectl config set-context --current --namespace argo-cd
argocd app list --core
```

## Port-forward scripts

The `tools` role installs convenience scripts to `$BIN_DIR` (default `$HOME/bin`,
which the role adds to `PATH`) for accessing services when ingress is unavailable
or from the devcontainer.

### `argo.sh`

Opens a port-forward to the ArgoCD server in the background.

```text
ArgoCD will be available at:
  https://argocd.<domain>
  or http://localhost:8080
  Login via GitHub (Dex)
```

GitHub sign-in through Dex redirects back to `https://argocd.<domain>`, so it
works only once ingress and the sealed OAuth credentials are in place; the
localhost port-forward does not complete a Dex login.

### `grafana.sh`

Opens a port-forward to Grafana on port 3000.

```text
Grafana will be available at:
  http://localhost:3000
  or https://grafana.<domain>
```

### `dashboard.sh`

Opens a port-forward to Headlamp on port 4466 in the background and prints a
24 hour token for the `headlamp` ServiceAccount, to paste into Headlamp's login
page (after the GitHub sign-in when going through the ingress).

```text
Login Token:
<printed>

Headlamp will be available at:
  https://headlamp.<domain>
or
  http://localhost:4466
```

## Shell configuration

The role configures these for both bash and zsh:

- `k` alias for `kubectl`
- Shell completions for `kubectl`, `helm`, `kubeseal`
- kubeconfig written to `~/.kube/config`

## Additional packages

The following are installed into the devcontainer for debugging:

| Package | Purpose |
|---------|---------|
| `iputils-ping` | `ping` command |
| `net-tools` | `netstat`, `ifconfig` |
| `dnsutils` | `dig`, `nslookup` |
| `vim` | Text editor |
| `sshpass` | SSH password authentication (for initial node access) |
