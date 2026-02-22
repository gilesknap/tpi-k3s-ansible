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
helm search repo longhorn/longhorn --versions
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

See [](../how-to/manage-sealed-secrets.md) for the full workflow.

## Port-forward scripts

The `tools` role installs convenience scripts to `/usr/local/bin/` for accessing
services when ingress is unavailable or from the devcontainer.

### `argo.sh`

Opens a port-forward to the ArgoCD server and prints the initial admin password.

```text
ArgoCD will be available at:
  https://argocd.gkcluster.org
  or https://localhost:8080
  Username: admin
  Initial Password: <printed>
```

### `grafana.sh`

Opens a port-forward to Grafana on port 3000.

```text
Grafana will be available at:
  http://localhost:3000
  or https://grafana.gkcluster.org
```

### `dashboard.sh`

Generates a Headlamp login token and opens a port-forward on port 8443.

```text
Login Token: <printed>
URL: https://dashboard.gkcluster.org
 or: https://localhost:8443
```

### `longhorn.sh`

Prompts you to set a basic-auth password for the Longhorn web UI, then prints the
access URL.

```text
Longhorn will be available at:
  https://longhorn.gkcluster.org
```

## Shell configuration

The role configures these for both bash and zsh:

- `k` alias for `kubectl`
- Shell completions for `kubectl`, `helm`, `kubeseal`
- `KUBECONFIG` set to the cluster kubeconfig

## Additional packages

The following are installed into the devcontainer for debugging:

| Package | Purpose |
|---------|---------|
| `iputils-ping` | `ping` command |
| `net-tools` | `netstat`, `ifconfig` |
| `dnsutils` | `dig`, `nslookup` |
| `vim` | Text editor |
| `sshpass` | SSH password authentication (for initial node access) |
