# Getting Started with Turing Pi

This tutorial walks you through setting up a K3s cluster on one or more Turing Pi v2.5
boards, from initial hardware setup to a fully deployed cluster with ArgoCD managing
all services.

## Prerequisites

### Hardware

- One or more **Turing Pi v2.5** boards
- Compute modules in each slot: **RK1** (8GB+) or **CM4** (4GB+)
- Network cable connecting each Turing Pi to your router
- **SD card** (≥8GB, ext4) inserted in each Turing Pi's BMC SD slot
- Optional: NVMe drives in the M.2 slots for OS migration

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

### Networking

Your workstation and Turing Pi boards must be on the **same subnet** with:

- DHCP enabled (router assigns IPs automatically)
- mDNS / zero-configuration networking enabled (so you can reach `turingpi.local`)

Verify your BMC is reachable:

```bash
ping turingpi.local
# Also try: turingpi, turingpi.lan, turingpi.broadband
```

:::{tip}
After the first boot, assign **fixed DHCP leases** (by MAC address) to each node in your
router's DHCP settings. This prevents IP changes on reboot.
:::

## Step 1: Clone the repository

```bash
git clone https://github.com/gilesknap/tpi-k3s-ansible.git
cd tpi-k3s-ansible
```

## Step 2: Generate an SSH keypair

Create a dedicated keypair for Ansible to use when connecting to all nodes:

```bash
# Run this on your HOST machine (outside the devcontainer)
ssh-keygen -t rsa -b 4096 -C "ansible master key" -f $HOME/.ssh/ansible_rsa
```

Use a strong passphrase. Then copy the public key into the repo:

```bash
cp $HOME/.ssh/ansible_rsa.pub pub_keys/ansible_rsa.pub
```

## Step 3: Authorize the keypair on each Turing Pi BMC

Repeat for each Turing Pi board:

```bash
# Copy the public key to the BMC (uses password auth — default password is empty or "turing")
scp pub_keys/ansible_rsa.pub root@turingpi:.ssh/authorized_keys

# Connect and secure the BMC
ssh root@turingpi

# Set a strong password
passwd

# Disable password authentication (key-only from now on)
sed -E -i 's|^#?(PasswordAuthentication)\s.*|\1 no|' /etc/ssh/sshd_config

exit
```

Ensure the SD card is mounted at `/mnt/sdcard` and formatted as ext4. This is where
OS images are stored during flashing.

## Step 4: Open the devcontainer

Open the repository in VS Code:

```bash
code .
```

When prompted, select **"Reopen in Container"** (or use
`Ctrl+Shift+P` → `Dev Containers: Reopen in Container`).

The devcontainer provides all required tools: Ansible, kubectl, helm, kubeseal, and more.
No additional installation is needed on your workstation.

## Step 5: Configure the inventory

Edit `hosts.yml` to match your hardware. The default inventory describes a single Turing Pi
with four nodes:

```yaml
turing_pis:
  hosts:
    turingpi:            # BMC hostname (must be reachable via SSH)
  vars:
    ansible_user: "{{ tpi_user }}"

turingpi_nodes:          # MUST be named <bmc_hostname>_nodes
  hosts:
    node01:
      slot_num: 1        # Physical slot (1-4, slot 1 nearest coin battery)
      type: pi4          # pi4 for CM4, rk1 for RK1
    node02:
      slot_num: 2
      type: rk1
      root_dev: /dev/nvme0n1   # Optional: migrate OS to NVMe
    node03:
      slot_num: 3
      type: rk1
      root_dev: /dev/nvme0n1
    node04:
      slot_num: 4
      type: rk1
      root_dev: /dev/nvme0n1
  vars:
    ansible_user: "{{ ansible_account }}"

all_nodes:
  children:
    turingpi_nodes:
```

Key points:

- The node group name **must** be `<bmc_hostname>_nodes` (e.g. `turingpi_nodes` for BMC
  host `turingpi`). The flash role uses this naming convention to discover nodes.
- `slot_num` maps each node to its physical slot on the Turing Pi board.
- `type` determines which OS image to flash (`rk1` or `pi4`).
- `root_dev` is optional — set it to migrate the OS from eMMC to NVMe after flashing.

## Step 6: Configure global variables

Edit `group_vars/all.yml`:

```yaml
# Change these to match your environment
control_plane: node01              # Which node is the K3s control plane
cluster_domain: gkcluster.org      # Your domain name
domain_email: you@example.com      # For Let's Encrypt certificates
repo_remote: https://github.com/gilesknap/tpi-k3s-ansible.git  # Your fork URL
repo_branch: main                  # Git branch for ArgoCD to track
admin_password: notgood            # Override on command line! (see below)
```

:::{warning}
Never commit a real password in `admin_password`. Always override it on the command line
with `-e admin_password=YourSecurePassword` when running the playbook.
:::

## Step 7: Run the playbook

From a terminal inside the devcontainer:

```bash
ansible-playbook pb_all.yml -e do_flash=true
```

This single command:

1. **`tools`** — installs helm, kubectl, kubeseal in the devcontainer
2. **`flash`** — flashes Ubuntu 24.04 to each compute module via the BMC
3. **`known_hosts`** — updates SSH known_hosts for all nodes
4. **`servers`** — migrates OS to NVMe (if configured), dist-upgrades, installs dependencies
5. **`k3s`** — installs K3s control plane and worker nodes
6. **`cluster`** — installs ArgoCD and deploys all cluster services

The full process takes approximately 15–30 minutes depending on network speed and
number of nodes.

:::{note}
The `-e do_flash=true` flag is required for the initial flash. On subsequent runs, omit it
to skip flashing (the playbook will check existing state and skip completed steps).
:::

## Step 8: Verify the cluster

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

## Next Steps

- {doc}`/how-to/bootstrap-cluster` — set up admin passwords and access cluster services
- {doc}`/how-to/cloudflare-tunnel` — expose services to the internet via Cloudflare
- {doc}`/how-to/manage-sealed-secrets` — manage encrypted secrets in the repository
- {doc}`/explanations/architecture` — understand how all the pieces fit together
