# Getting Started without Turing Pi

This tutorial walks you through deploying a K3s cluster on **any set of Linux servers**
that are already running Ubuntu 24.04 LTS — no Turing Pi hardware required.

All Ansible roles except the BMC flashing step work identically on standalone servers,
Intel NUCs, Raspberry Pis, VMs, or cloud instances.

## Prerequisites

### Target Servers

- **One or more** Linux servers running **Ubuntu 24.04 LTS**
- SSH access from your workstation to each server
- All servers on the **same subnet** (or with routable network connectivity)
- One server designated as the **control plane**; any extras are **workers**

:::{tip}
A single server works fine — K3s runs as both control plane and worker. The
control-plane `NoSchedule` taint is automatically skipped when there is only
one node, so all workloads schedule on it.
:::

### Software (on your workstation)

- **Linux** workstation (or WSL2 on Windows)
- **podman** 4.3 or later
- **VS Code** with the
  [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
  extension
- **git**

:::{note}
Set the VS Code setting `dev.containers.dockerPath` to `podman`.
:::

## Step 1: Clone the repository

```bash
git clone https://github.com/gilesknap/tpi-k3s-ansible.git
cd tpi-k3s-ansible
```

## Step 2: Generate an SSH keypair

```bash
# Run this on your HOST machine (outside the devcontainer)
ssh-keygen -t rsa -b 4096 -C "ansible master key" -f $HOME/.ssh/ansible_rsa
cp $HOME/.ssh/ansible_rsa.pub pub_keys/ansible_rsa.pub
```

## Step 3: Open the devcontainer

```bash
code .
# Select "Reopen in Container" when prompted
```

## Step 4: Bootstrap Ansible access on your servers

The `pb_add_nodes.yml` playbook creates an `ansible` user on each server with SSH key
authentication and passwordless sudo. You need an existing user account with SSH + sudo
access to run this initial bootstrap.

First, add your servers to `hosts.yml` under the `extra_nodes` group:

```yaml
extra_nodes:
  hosts:
    server1:        # Hostname or IP of your control plane
    server2:        # Worker node
    server3:        # Worker node
  vars:
    ansible_user: "{{ ansible_account }}"

all_nodes:
  children:
    extra_nodes:    # Only extra_nodes — no turingpi_nodes needed
```

:::{note}
You can remove or comment out the `turing_pis` and `turingpi_nodes` groups entirely
if you have no Turing Pi hardware.
:::

Then run the bootstrap playbook:

```bash
ansible-playbook pb_add_nodes.yml
```

You will be prompted for:

- **Username** — an existing SSH user on all servers
- **Password** — that user's password (used for initial sudo)

The playbook creates the `ansible` user with your SSH key and passwordless sudo on
every server in `extra_nodes`.

## Step 5: Verify SSH access

Confirm Ansible can reach all nodes with the new `ansible` user:

```bash
ansible all_nodes -m ping
```

Expected output:

```
server1 | SUCCESS => { "ping": "pong" }
server2 | SUCCESS => { "ping": "pong" }
server3 | SUCCESS => { "ping": "pong" }
```

## Step 6: Configure global variables

Edit `group_vars/all.yml`:

```yaml
control_plane: server1             # Your designated control plane node
cluster_domain: example.com        # Your domain name
domain_email: you@example.com      # For Let's Encrypt certificates
repo_remote: https://github.com/you/tpi-k3s-ansible.git
repo_branch: main
```

Ensure `control_plane` matches one of the hostnames in your `extra_nodes` group.

## Step 7: Run the playbook (skip flash)

Since your servers already have an OS installed, skip the `flash` tag and run:

```bash
ansible-playbook pb_all.yml --tags known_hosts,servers,k3s,cluster
```

This runs only the relevant stages:

1. **`known_hosts`** — updates SSH known_hosts for all nodes
2. **`servers`** — dist-upgrade, installs dependencies (`open-iscsi`, etc.)
3. **`k3s`** — installs K3s control plane and worker nodes
4. **`cluster`** — installs ArgoCD and deploys all cluster services

:::{note}
The `tools` tag (helm, kubectl installation in the devcontainer) runs automatically as
part of the devcontainer setup. You can include it explicitly if needed:
`--tags tools,known_hosts,servers,k3s,cluster`
:::

### What about `move_fs`?

The `move_fs` role (OS migration to NVMe) runs as part of the `servers` tag. It only
activates if a node has `root_dev` defined in the inventory. If your servers are already
running from their desired disk, simply omit `root_dev` from the inventory and the
role does nothing.

## Step 8: Verify the cluster

```bash
kubectl get nodes
```

```
NAME      STATUS   ROLES                       AGE   VERSION
server1   Ready    control-plane,etcd,master   5m    v1.31.x+k3s1
server2   Ready    <none>                      4m    v1.31.x+k3s1
server3   Ready    <none>                      4m    v1.31.x+k3s1
```

```bash
kubectl get applications -n argo-cd
```

All applications should reach `Synced` and `Healthy` status within a few minutes.

## DNS Configuration

For ingress to work, DNS entries for `*.<your-domain>` must point to **one or more
worker node IPs** (not the control plane). The ingress-nginx LoadBalancer runs on
worker nodes.

For example, if using Cloudflare DNS:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `argocd` | `192.168.1.102` | DNS only |
| A | `grafana` | `192.168.1.102` | DNS only |
| A | `longhorn` | `192.168.1.102` | DNS only |

Alternatively, set up a wildcard A record if you do not need Cloudflare proxy features:

```
*.example.com  A  192.168.1.102
```

## Next Steps

- {doc}`/how-to/bootstrap-cluster` — set up admin passwords and access cluster services
- {doc}`/how-to/cloudflare-tunnel` — expose services to the internet via Cloudflare
- {doc}`/how-to/add-remove-services` — customise which services are deployed
- {doc}`/how-to/alternative-storage` — use a different storage provider instead of Longhorn
