# Variables Reference

All configurable variables, their defaults, and where they are used.

## Global variables (`group_vars/all.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `ansible_account` | `ansible` | Username for the Ansible SSH user on all nodes |
| `tpi_user` | `root` | SSH user for Turing Pi BMC connections |
| `tpi_images_path` | `/mnt/sdcard/images` | Path on BMC SD card for OS images |
| `vault_password_file` | `~/.ansible_vault_password` | Path to Ansible vault password file |
| `bin_dir` | `$HOME/bin` (from `$BIN_DIR` env) | Directory for CLI tools (helm, kubectl, etc.) |
| `do_flash` | `false` | Enable flashing (derived from `flash_force` / `force_flash`) |
| `local_domain` | `.lan` | Local domain suffix for mDNS |
| `control_plane` | `node01` | Hostname of the K3s control plane node |
| `backup_age_recipient` | `""` | age public key the nightly etcd backup and secrets backup are encrypted to (the root app passes it to the `backups` app). Empty makes both fail without uploading. `etcd_backup_age_recipient` defaults to it. |
| `cluster_domain` | `<domain>` | Domain name for ingress hosts |
| `domain_email` | `your.email@...` | Email for Let's Encrypt certificate registration |
| `repo_remote` | `https://github.com/gilesknap/tpi-k3s-ansible.git` | Git repo URL for ArgoCD |
| `repo_branch` | `main` | Git branch for ArgoCD (also in `kubernetes-services/values.yaml`) |
| `cluster_install_list` | `[argocd]` | List of services installed directly by Ansible |

## Role-specific variables

### Host variables (inventory)

Set per-host in `hosts.yml` under the relevant host entry:

| Variable | Default | Description |
|----------|---------|-------------|
| `slot_num` | — | Turing Pi BMC slot number (1–4), required for Turing Pi nodes |
| `type` | — | Module type: `rk1` or `pi4` |
| `root_dev` | — | Block device to migrate root filesystem to (e.g. `/dev/nvme0n1`) |
| `nvidia_gpu_node` | `false` | Set `true` on nodes with an NVIDIA GPU. Installs the NVIDIA driver and container toolkit, configures k3s containerd with the NVIDIA runtime, and labels the node `nvidia.com/gpu.present=true` so the device plugin DaemonSet can schedule. |

### `tools` role (`roles/tools/vars/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `tools_zshrc` | (path) | Zsh completion directory path |
| `tools_bashrc` | (path) | Bash completion directory path |
| `tools_shell` | (list) | Shell config files to source completions from |
| `tools_additional_packages` | `ping, net-tools, dnsutils, vim, sshpass` | Extra packages installed in devcontainer |

### `flash` role (`roles/flash/vars/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `flash_force` | `false` | Force re-flash even if node is contactable |
| `flash_local_tmp` | `/tmp` | Local directory for downloading OS images |
| `flash_pre_flashed` | `false` | Skip flashing for pre-flashed nodes |
| (image URLs/SHAs) | (hardcoded) | OS image download URLs and checksums for RK1 and CM4 |

### `k3s` role (`roles/k3s/vars/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `k3s_force` | `false` | Force K3s reinstall (uninstall first) |
| `k3s_install_occurred` | `false` | Internal flag tracking if install happened this run |

### `etcd_backup` role (`roles/etcd_backup/defaults/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `etcd_backup_age_recipient` | `backup_age_recipient` | age public key for the etcd bundles; set only to use a different key from the secrets backup |
| `etcd_backup_nfs_server` / `etcd_backup_nfs_path` | `nfs.server` / `nfs.cluster_share_path` from `kubernetes-services/values.yaml` | NAS export the bundles are written to |
| `etcd_backup_mount_point` | `/mnt/k8s-cluster` | Where the share is mounted while the job runs |
| `etcd_backup_dest_subdir` | `backups/etcd` | Destination directory below the mount point |
| `etcd_backup_keep` | `14` | Nightly bundles kept on the NAS |
| `etcd_backup_extra_prefixes` | `[pre-upgrade]` | Snapshot name prefixes also shipped, once each, to `<dest>/<prefix>/` |
| `etcd_backup_extra_keep` | `4` | Bundles kept per extra prefix |
| `etcd_backup_on_calendar` | `*-*-* 23:15:00 Europe/London` | systemd `OnCalendar` schedule |
| `etcd_backup_textfile_dir` | `/var/lib/node_exporter/textfile_collector` | node-exporter textfile directory for the job's metrics |

### `cluster` role (`roles/cluster/vars/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_force` | `false` | Force ArgoCD reinstall |

## Command-line overrides

Variables can be overridden on the command line with `-e`:

```bash
ansible-playbook pb_all.yml \
  -e flash_force=true \
  -e k3s_force=true \
  -e repo_branch=my-feature-branch \
  -e repo_remote=https://github.com/me/my-fork.git
```

(argocd-helm-values)=
## ArgoCD Helm values (`kubernetes-services/values.yaml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `repo_branch` | `main` | Branch for child ArgoCD Applications' `targetRevision` |
| `enable_oauth2_proxy` | `false` | Enable OAuth2 proxy authentication on protected services. Set `true` after completing OAuth setup ({doc}`/how-to/oauth-setup`). |
| `enable_cloudflare_tunnel` | `false` | Disable SSL redirect on tunnelled services for Cloudflare Tunnel compatibility. Set `true` after adding public hostnames ({doc}`/how-to/cloudflare-web-tunnel`). |
| `admin_emails` | *(list of emails)* | GitHub-linked email addresses with full admin access to all OAuth-protected services |
| `nfs.server` | *(your NFS server IP)* | NFS server for the backup and Minecraft volumes |
| `nfs.cluster_share_path` | *(your NFS export path)* | Cluster-owned directory on the NFS export (see {doc}`/how-to/nas-setup`) |
| `enable_minecraft` | `true` | Deploy the Minecraft dashboard ({doc}`/how-to/minecraft`) |
| `minecraft.chart_version` | `0.2.0` | Version of the `ghcr.io/gilesknap/charts/minecraft-dashboard` OCI chart (image tag follows the chart's appVersion) |
| `minecraft.archive_path` | `/bigdisk/minecraft-archive` | Read-only NFS path of the world archive on `nfs.server` (outside the cluster share) |
| `minecraft.store_subdir` | `minecraft` | Writable store directory under `nfs.cluster_share_path` |
| `minecraft.dns_name` | `mc` | Players connect to `<dns_name>.<cluster_domain>` |
| `minecraft.worlds.node` | *(node name)* | Node all worlds are pinned to — the VPS relay forward target |
| `minecraft.worlds.port_min` / `port_max` | `30565` / `30584` | Inclusive NodePort range for game ports |
| `minecraft.worlds.rcon_port_min` / `rcon_port_max` | `30600` / `30619` | Inclusive NodePort range for per-world RCON (LAN only; never relay it) |
| `minecraft.worlds.rcon_allowed_cidrs` | LAN CIDRs | Sources allowed to reach world RCON through the dashboard's NetworkPolicy (CIDR or `{cidr, except}`) |
| `enable_vps_relay` | `false` | Deploy the VPS relay ({doc}`/how-to/vps-relay`); needs the `vps-relay-credentials` SealedSecret |
| `vps_relay.vps_tailnet_host` | *(tailnet IP or name)* | The VPS's tailnet IP or MagicDNS name, where frps listens |
| `vps_relay.frp_port` | `7000` | frps control port on the VPS's tailnet address |
| `vps_relay.forwards` | *(minecraft entry)* | List of `name`, `protocol` (`tcp`/`udp`), `ports` (port or `min-max`) and `target`; each publishes `ports` on the VPS and relays them to the same ports on `target`. The VPS's `allowPorts` and firewall must match |

The `repo_branch` value is self-referential — ArgoCD reads it from the same branch it
is tracking. Each branch must set this to match its own branch name.

The `nfs.*` values are the **single source of truth** for NFS configuration.
ArgoCD injects them directly into the Helm charts that use them; no corresponding Ansible
variable is needed because Ansible does not create the PersistentVolume.

## Environment variables

| Variable | Set in | Description |
|----------|--------|-------------|
| `BIN_DIR` | `devcontainer.json` | Directory for CLI tools (`/root/bin`) |
| `ZSHRC` | `devcontainer.json` | Path to zsh config |
| `ANSIBLE_VAULT_PASSWORD_FILE` | `devcontainer.json` | Vault password file path |
