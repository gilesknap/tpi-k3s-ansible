# Getting Started with Turing Pi

:::{tip}
For an interactive experience, try the {doc}`ai-guided-setup` instead — Claude Code
will walk you through these steps, configure files, generate secrets, and run the
playbooks for you.
:::

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

```{include} common-setup.md
:start-after: <!-- begin:software-prereqs -->
:end-before: <!-- end:software-prereqs -->
```

### Networking

Your workstation and Turing Pi boards must be on the **same subnet** with these network features:

- DHCP enabled (router assigns IPs automatically)
- mDNS / zero-configuration networking enabled (so you can reach `turingpi.local`)

:::{note}
mDNS is enabled by default on macOS, most Linux desktop distributions (via
Avahi), and Windows 10+. If `turingpi.local` doesn't resolve, check that
the `avahi-daemon` service is running on Linux (`sudo systemctl start avahi-daemon`)
or install it with `sudo apt install avahi-daemon`. On Windows, mDNS support
is built into the OS — no extra setup needed.
:::

Verify your BMC is reachable:

```bash
ping turingpi.local
# Also try: turingpi, turingpi.lan, turingpi.broadband
```

:::{tip}
After the first boot, assign **fixed DHCP leases** (by MAC address) to each node in your
router's DHCP settings. This prevents IP changes on reboot.
:::

## Step 1: Fork, clone, and generate SSH key

```{include} common-setup.md
:start-after: <!-- begin:fork-clone -->
:end-before: <!-- end:fork-clone -->
```

```{include} common-setup.md
:start-after: <!-- begin:ssh-keygen -->
:end-before: <!-- end:ssh-keygen -->
```

## Step 2: Authorize the keypair on each Turing Pi BMC

Repeat for each Turing Pi board:

```bash
# Copy the public key to the BMC (uses password auth — default password is empty or "turing")
scp pub_keys/ansible_rsa.pub root@turingpi:.ssh/authorized_keys

# Connect and secure the BMC
ssh root@turingpi

# Set a strong password
passwd

# Optional: Disable password authentication (key-only from now on)
# WARNING: test that ssh works without password (i.e. the new key works) before disabling password auth, or you may lock yourself out!
sed -E -i 's|^#?(PasswordAuthentication)\s.*|\1 no|' /etc/ssh/sshd_config

exit
```

Ensure the SD card is mounted at `/mnt/sdcard` and formatted as ext4. This is where
OS images are stored during flashing.

## Step 3: Open the devcontainer

```{include} common-setup.md
:start-after: <!-- begin:devcontainer -->
:end-before: <!-- end:devcontainer -->
```

## Step 4: Configure the inventory

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

## Step 5: Configure the cluster

```{include} common-setup.md
:start-after: <!-- begin:configure-cluster -->
:end-before: <!-- end:configure-cluster -->
```

## Step 6: Run the playbook

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

The Ansible steps are idempotent, and will skip flashing nodes that already have
Ubuntu installed. But ommitting do_flash protects against accidental re-flashing of
nodes that are temporarily offline or have connectivity issues.
:::

## Step 7: Verify the cluster

```{include} common-setup.md
:start-after: <!-- begin:verify-cluster -->
:end-before: <!-- end:verify-cluster -->
```

```{include} common-setup.md
:start-after: <!-- begin:next-steps -->
:end-before: <!-- end:next-steps -->
```
