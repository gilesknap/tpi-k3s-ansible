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
  https://argocd.<domain>
  or https://localhost:8080
  Username: admin
  Initial Password: <printed>
```

### `grafana.sh`

Opens a port-forward to Grafana on port 3000.

```text
Grafana will be available at:
  http://localhost:3000
  or https://grafana.<domain>
```

### `dashboard.sh`

Generates a Headlamp login token and opens a port-forward on port 8443.

```text
Login Token: <printed>
URL: https://dashboard.<domain>
 or: https://localhost:8443
```

### `longhorn.sh`

Prompts you to set a basic-auth password for the Longhorn web UI, then prints the
access URL.

```text
Longhorn will be available at:
  https://longhorn.<domain>
```

## Shell configuration

The role configures these for both bash and zsh:

- `k` alias for `kubectl`
- Shell completions for `kubectl`, `helm`, `kubeseal`
- `KUBECONFIG` set to the cluster kubeconfig

## Model management scripts

### `rkllama-pull`

Searches HuggingFace for RKLLM models and downloads them to the cluster's NFS share
via `kubectl exec`. See {doc}`/how-to/rkllama-models` for full usage.

```bash
rkllama-pull [search terms ...]   # search and download
rkllama-pull --delete             # list installed models and delete one
```

### `llamacpp-pull`

Searches HuggingFace for GGUF models and downloads them to the llamacpp NFS share
via `kubectl exec`. Also supports switching the active model and listing/deleting
models. See {doc}`/how-to/llamacpp-models` for full usage.

```bash
llamacpp-pull [search terms ...]  # search and download (optionally activate)
llamacpp-pull --list              # list GGUF models on the NFS share
llamacpp-pull --set               # switch the active model
llamacpp-pull --delete            # delete a model from the NFS share
```

:::{note}
`llamacpp-pull --set` patches the running Deployment directly and will be reverted
by ArgoCD on the next sync. To permanently switch models, update
`llamacpp.model.file` in `kubernetes-services/values.yaml` and push.
:::

## Additional packages

The following are installed into the devcontainer for debugging:

| Package | Purpose |
|---------|---------|
| `iputils-ping` | `ping` command |
| `net-tools` | `netstat`, `ifconfig` |
| `dnsutils` | `dig`, `nslookup` |
| `vim` | Text editor |
| `sshpass` | SSH password authentication (for initial node access) |
