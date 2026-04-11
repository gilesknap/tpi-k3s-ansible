# Common Setup Steps

This page contains setup steps shared by both the
{doc}`getting-started-tpi` and {doc}`getting-started-generic` tutorials.
You do not need to read this page on its own — it is included automatically
in the tutorial you are following.

## Prerequisites

<!-- begin:software-prereqs -->
### Software (on your workstation)

- **Linux** workstation (or WSL2 on Windows)
- **podman** 4.3 or later (rootless container runtime)
- **VS Code** with the
  [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
  extension
- **git**

:::{note}
Set the VS Code setting `dev.containers.dockerPath` to `podman` before proceeding.
:::
<!-- end:software-prereqs -->

<!-- begin:fork-clone -->
## Fork and clone the repository

1. **Fork** the repository on GitHub: visit
   [gilesknap/tpi-k3s-ansible](https://github.com/gilesknap/tpi-k3s-ansible)
   and click **Fork**.

2. Clone your fork:

```bash
git clone https://github.com/<your-username>/tpi-k3s-ansible.git
cd tpi-k3s-ansible
```

:::{note}
You need your own fork because ArgoCD tracks *your* repository for GitOps.
Changes you push to your fork are automatically deployed to your cluster.

The repo contains SealedSecret files encrypted for the original cluster —
these won't work on yours and can be safely ignored until you create your
own during {doc}`/how-to/cloudflare-tunnel` setup.
:::
<!-- end:fork-clone -->

<!-- begin:ssh-keygen -->
## Generate an SSH keypair

Create a dedicated keypair for Ansible to use when connecting to all nodes:

```bash
# Run this on your HOST machine (outside the devcontainer)
ssh-keygen -t rsa -b 4096 -C "ansible master key" -f $HOME/.ssh/ansible_rsa
```

Use a strong passphrase. Then copy the public key into the repo:

```bash
cp $HOME/.ssh/ansible_rsa.pub pub_keys/ansible_rsa.pub
```
<!-- end:ssh-keygen -->

<!-- begin:devcontainer -->
## Open the devcontainer

Open the repository in VS Code:

```bash
code .
```

When prompted, select **"Reopen in Container"** (or use
`Ctrl+Shift+P` → `Dev Containers: Reopen in Container`).

The devcontainer provides Ansible (and its Python dependencies) out of the box.
Cluster tools (kubectl, helm, kubeseal) are installed later by the `tools` role when
you run the playbook. No additional installation is needed on your workstation.
<!-- end:devcontainer -->

<!-- begin:configure-cluster -->
## Configure the cluster

Edit `group_vars/all.yml` — the primary Ansible configuration:

```yaml
# Change these to match your environment
control_plane: node01              # Which node is the K3s control plane
cluster_domain: example.com        # Your domain name
domain_email: you@example.com      # For Let's Encrypt certificates
repo_remote: https://github.com/<your-username>/tpi-k3s-ansible.git
repo_branch: main                  # Git branch for ArgoCD to track
```

Then edit `kubernetes-services/values.yaml` — the ArgoCD runtime configuration:

```yaml
repo_branch: main                  # Must match the value in all.yml

# OAuth2 authentication gateway — leave false for initial setup.
# Enable after completing the OAuth guide (docs/how-to/oauth-setup).
enable_oauth2_proxy: false

# OAuth2 email allowlist — GitHub-linked emails allowed to access
# protected services. Remove the defaults and add your own:
admin_emails:
  - you@example.com

# NFS configuration (optional — only needed for LLM features)
rkllama:
  nfs:
    server: 192.168.1.3            # Your NFS server IP
    path: /path/to/rkllm/models    # NFS export path for rkllm models
llamacpp:
  nfs:
    server: 192.168.1.3
    path: /path/to/gguf/models
  model:
    file: "your-model.gguf"
```

:::{tip}
If you do not have an NFS server or do not plan to use the LLM features (rkllama,
llamacpp), you can leave the NFS settings as-is. The services will deploy but remain
idle until configured.
:::

:::{important}
**NFS is also a prerequisite for backups.** The daily and weekly backup
CronJobs write stateful-service dumps (Supabase DB, Grafana, Open WebUI,
…) to a shared NFS tree on a NAS. If you plan to run backups — strongly
recommended for any stateful workload — set up the NAS share before the
first backup fires using {doc}`/how-to/nas-setup`. This is a one-time
manual runbook on the NAS itself (Ansible has no access to it by design).
:::

:::{note}
`enable_oauth2_proxy` controls whether cluster services require GitHub login.
Leave it `false` until you have completed the {doc}`/how-to/oauth-setup` guide —
otherwise services like Grafana will return errors because the
OAuth proxy is not yet deployed.
:::
<!-- end:configure-cluster -->

<!-- begin:verify-cluster -->
## Verify the cluster

After the playbook completes:

```bash
kubectl get nodes
```

Expected output shows all nodes in `Ready` state:

```
NAME     STATUS   ROLES                       AGE   VERSION
node01   Ready    control-plane,etcd,master   5m    v1.31.x+k3s1
node02   Ready    <none>                      4m    v1.31.x+k3s1
node03   Ready    <none>                      4m    v1.31.x+k3s1
node04   Ready    <none>                      4m    v1.31.x+k3s1
```

Check ArgoCD applications:

```bash
kubectl get applications -n argo-cd
```

All applications should eventually reach `Synced` and `Healthy` status.
<!-- end:verify-cluster -->

<!-- begin:next-steps -->
## Next Steps

- {doc}`/how-to/bootstrap-cluster` — set up admin passwords and access cluster services
- {doc}`/how-to/cloudflare-tunnel` — expose services to the internet via Cloudflare
- {doc}`/how-to/oauth-setup` — secure services with GitHub OAuth (enable `enable_oauth2_proxy` after setup)
- {doc}`/how-to/manage-sealed-secrets` — manage encrypted secrets in the repository
- {doc}`/explanations/architecture` — understand how all the pieces fit together
<!-- end:next-steps -->
