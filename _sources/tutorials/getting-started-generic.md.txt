# Getting Started without Turing Pi

:::{tip}
For an interactive experience, try the {doc}`ai-guided-setup` instead — Claude Code
will walk you through these steps, configure files, generate secrets, and run the
playbooks for you.
:::

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

```{include} common-setup.md
:start-after: <!-- begin:software-prereqs -->
:end-before: <!-- end:software-prereqs -->
```

## Step 1: Fork, clone, and generate SSH key

```{include} common-setup.md
:start-after: <!-- begin:fork-clone -->
:end-before: <!-- end:fork-clone -->
```

```{include} common-setup.md
:start-after: <!-- begin:ssh-keygen -->
:end-before: <!-- end:ssh-keygen -->
```

## Step 2: Open the devcontainer

```{include} common-setup.md
:start-after: <!-- begin:devcontainer -->
:end-before: <!-- end:devcontainer -->
```

## Step 3: Bootstrap Ansible access on your servers

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

## Step 4: Verify SSH access

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

## Step 5: Configure the cluster

```{include} common-setup.md
:start-after: <!-- begin:configure-cluster -->
:end-before: <!-- end:configure-cluster -->
```

Ensure `control_plane` matches one of the hostnames in your `extra_nodes` group.

## Step 6: Run the playbook (skip flash)

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
The `tools` tag installs helm, kubectl, and kubeseal into the devcontainer (`localhost`).
It is **not** run automatically by the devcontainer build — you must run it manually
(or include it in the playbook run, as shown above):

```bash
ansible-playbook pb_all.yml --tags tools
```

The installed binaries are placed in `/root/bin` which is backed by the `iac2-bin`
Docker volume, so they persist across container rebuilds.
:::

### What about `move_fs`?

The `move_fs` role (OS migration to NVMe) runs as part of the `servers` tag. It only
activates if a node has `root_dev` defined in the inventory. If your servers are already
running from their desired disk, simply omit `root_dev` from the inventory and the
role does nothing.

## Step 7: Verify the cluster

```{include} common-setup.md
:start-after: <!-- begin:verify-cluster -->
:end-before: <!-- end:verify-cluster -->
```

```{include} common-setup.md
:start-after: <!-- begin:next-steps -->
:end-before: <!-- end:next-steps -->
```
