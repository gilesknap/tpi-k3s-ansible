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
| `local_domain` | `.lan` | Local domain suffix; `known_hosts` looks up `<node>{{ local_domain }}` to find a node's IPs |
| `control_plane` | `node02` | Hostname of the K3s control plane node |
| `standby_control_plane` | `node03` | Warm-standby control plane: the spare node a restore goes onto ({doc}`/how-to/recover-control-plane`). The `cluster` tag taints it `node-role.kubernetes.io/standby-control-plane:PreferNoSchedule` and removes that taint from any other node. Empty for none |
| `dns_router` | `root@192.168.1.1` | SSH target of an OpenWrt (dnsmasq, `uci`) router, used only by `just k3s-api-dns <ip>` to point `k3s_api_name` at the control plane. |
| `k3s_api_name` | `k3s.lan` | Stable DNS name for the Kubernetes API, resolving to the control plane. Agents join it, it is a `tls-san` on the server certificate, and the kubeconfig uses it. Every address it resolves to must be the control plane's. Without LAN DNS, the control plane's IPv4 address also works; an IPv6 literal does not. |
| `etcd_backup_age_recipient` | `""` | age public key the nightly etcd backup is encrypted to. Empty makes the backup fail without uploading. |
| `cluster_domain` | `<domain>` | Domain name for ingress hosts |
| `domain_email` | `your.email@...` | Email for Let's Encrypt certificate registration |
| `repo_remote` | `https://github.com/gilesknap/tpi-k3s-ansible.git` | Git repo URL for ArgoCD |
| `repo_branch` | `main` | Git branch for ArgoCD (also in `kubernetes-services/values.yaml`) |
| `k3s_minor` | `k3s.minor` from `kubernetes-services/values.yaml` | k3s minor line the cluster follows (e.g. `v1.34`). Edit it in `values.yaml`, not here. |
| `cluster_install_list` | `[argocd]` | List of services installed directly by Ansible |

## Role-specific variables

### Host variables (inventory)

Set per-host in `hosts.yml` under the relevant host entry:

| Variable | Default | Description |
|----------|---------|-------------|
| `slot_num` | — | Turing Pi BMC slot number (1–4), required for Turing Pi nodes |
| `type` | — | Module type: `rk1` or `pi4` |
| `root_dev` | — | RK1 only: the disk to install the OS on (e.g. `/dev/nvme0n1`) |
| `nvidia_gpu_node` | `false` | Set `true` on nodes with an NVIDIA GPU. Installs the NVIDIA driver and container toolkit, configures k3s containerd with the NVIDIA runtime, and labels the node `nvidia.com/gpu.present=true` so the device plugin DaemonSet can schedule. |
| `intel_gpu_node` | `false` | Set `true` on nodes with an Intel iGPU. Labels the node `intel.feature.node.kubernetes.io/gpu=true` so the Intel GPU device plugin DaemonSet runs there and advertises `gpu.intel.com/i915`. Installs nothing on the node. |

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
| `flash_force` | `false` | Force re-flash even if node is contactable; on an RK1 with `root_dev`, also the only way to wipe an NVMe that has a partition table |
| `flash_local_tmp` | `/tmp/iac2` | Local directory for downloading OS images |
| `flash_pre_flashed` | `false` | Skip flashing for pre-flashed nodes |
| `flash_image_info` | (pinned) | CM4 OS image URL and checksum |
| `flash_rk1_uboot_deb`, `flash_rk1_uboot_deb_file` | (pinned) | Armbian's mainline U-Boot package for the RK1: URL, sha256, and the path and sha256 of `u-boot-rockchip.bin` in it |
| `flash_rk1_os_vers`, `flash_rk1_os_image` | `26.04.1` (pinned) | Ubuntu's preinstalled server image for the RK1: URL and sha256, and the decompressed image's sha256 and size, which the install checks on the NVMe |
| `flash_rk1_emmc_sha256` | (pinned) | sha256 of the uncompressed eMMC staging image built from the two above |
| `flash_rk1_cache_dir` | `{{ flash_local_tmp }}/rk1` | Controller cache for the RK1 downloads and the built image (about 6 GB at the peak of a build) |
| `flash_seed_ssh_keys` | ansible key (+ Claude key) | Keys authorised for the `ansible` account by the RK1 cloud-init seed |

### `k3s` role (`roles/k3s/vars/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `k3s_force` | `false` | Force K3s reinstall (uninstall first) |
| `k3s_install_occurred` | `false` | Internal flag tracking if install happened this run |
| `k3s_version` | unset | Exact release to install (e.g. `v1.34.6+k3s1`), on the `k3s_minor` line. Unset: the control plane takes the channel's newest patch and workers the control plane's version. |

### `etcd_backup` role (`roles/etcd_backup/defaults/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `etcd_backup_nfs_server` / `etcd_backup_nfs_path` | `nfs.server` / `nfs.cluster_share_path` from `kubernetes-services/values.yaml` | NAS export the bundles are written to |
| `etcd_backup_mount_point` | `/mnt/k8s-cluster` | Where the share is mounted while the job runs |
| `etcd_backup_dest_subdir` | `backups/etcd` | Destination directory below the mount point |
| `etcd_backup_keep` | `14` | Nightly bundles kept on the NAS |
| `etcd_backup_extra_prefixes` | `[pre-upgrade]` | Snapshot name prefixes also shipped to `<dest>/<prefix>/`: the earliest snapshot of each name, once |
| `etcd_backup_extra_keep` | `4` | Bundles kept per extra prefix |
| `etcd_backup_on_calendar` | `*-*-* 23:15:00 Europe/London` | systemd `OnCalendar` schedule |
| `etcd_backup_sealed_secrets_namespace` | `kube-system` | Namespace whose sealed-secrets keys the job also exports, encrypted, to `<dest>/sealed-secrets-keys.yaml.age` |
| `etcd_backup_textfile_dir` | `/var/lib/node_exporter/textfile_collector` | node-exporter textfile directory for the job's metrics |

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
| `enable_oauth2_proxy` | `true` | Enable OAuth2 proxy authentication on protected services. A new fork starts with `false` and sets `true` after completing OAuth setup ({doc}`/how-to/oauth-setup`). |
| `enable_cloudflare_tunnel` | `true` | Disable SSL redirect on tunnelled services for Cloudflare Tunnel compatibility. A new fork starts with `false` and sets `true` after adding public hostnames ({doc}`/how-to/cloudflare-web-tunnel`). |
| `admin_emails` | *(list of emails)* | GitHub-linked email addresses with full admin access to all OAuth-protected services |
| `nfs.server` | *(your NFS server IP)* | NFS server for the backup and Minecraft volumes |
| `nfs.cluster_share_path` | *(your NFS export path)* | Cluster-owned directory on the NFS export (see {doc}`/how-to/nas-setup`) |
| `nfs_csi.server` | *(your NFS server IP)* | NFS server for the dynamic StorageClasses |
| `nfs_csi.share` | `/k8s-dynamic` | Export for `nfs-rwx` scratch volumes (a new folder per PV) |
| `nfs_csi.stable_share` | `/k8s-dynamic/stable` | Folder for `nfs-stable` volumes (one fixed folder per PVC); keep it a subfolder of `share` |
| `nfs_csi.chart_version` | `4.13.4` | csi-driver-nfs chart version |
| `nfs_csi.fresh_storage_class` | `nfs-rwx` | Name of the scratch StorageClass, used only when named |
| `nfs_csi.stable_storage_class` | `nfs-stable` | Name of the default StorageClass |
| `enable_jellyfin` | `true` | Deploy Jellyfin ({doc}`/how-to/jellyfin`); needs `local_storage.jellyfin` and its `k8s_data_dirs` entry |
| `jellyfin.chart_version` / `image_tag` | `3.7.0` / `12.4.…` | The upstream chart version and the Jellyfin image tag (never older than the database's Jellyfin) |
| `jellyfin.trial` | `false` | Throwaway trial config: marks the config volume `TRIAL-CONFIG-SAFE-TO-DELETE`. Not with `seed_from_host` |
| `jellyfin.seed_from_host` | `true` | One-off copy of a stopped host install into the config volume (init containers); a no-op once the volume is `SEEDED-FROM-HOST` |
| `jellyfin.seed.sqlite_image` | `docker.io/keinos/sqlite3:3.54.1` | Image with `sqlite3`, for the seed's integrity check and the backup CronJobs |
| `jellyfin.seed.hardware_decoding_codecs` | `[h264, hevc, …]` | Replaces `HardwareDecodingCodecs` in the copied `encoding.xml`; empty leaves it unchanged |
| `jellyfin.data_dir` / `config_dir` / `log_dir` / `cache_dir` | `/var/lib/jellyfin` / `/etc/jellyfin` / `/var/log/jellyfin` / `/var/cache/jellyfin` | Jellyfin's paths in the pod, the same as a host install's. The first three are the config volume's `data/`, `config/` and `log/`; the seed copies the host's `data_dir` and `config_dir` |
| `jellyfin.host_network` | `true` | Run on the node's network (both LANs, Tailscale, UDP 7359 discovery); off for a trial beside a host install |
| `jellyfin.uid` / `gid` | `122` / `124` | The node's `jellyfin` account; must match the `k8s_data_dirs` owner |
| `jellyfin.render_gid` / `video_gid` | `992` / `44` | The node's `render` and `video` groups, for `/dev/dri` |
| `jellyfin.media.nfs_path` / `mount_path` | `/bigdisk/media` / `/media/bigdisk/media` | The library's NFS export on `nfs.server`, and where the pod mounts it read-only |
| `enable_minecraft` | `true` | Deploy the Minecraft dashboard ({doc}`/how-to/minecraft`) |
| `minecraft.chart_version` | `0.5.2` | Version of the `ghcr.io/gilesknap/charts/minecraft-dashboard` OCI chart (image tag follows the chart's appVersion) |
| `minecraft.archive_path` | `/bigdisk/minecraft-archive` | Read-only NFS path of the world archive on `nfs.server` (outside the cluster share) |
| `minecraft.store_subdir` | `minecraft` | Writable store directory under `nfs.cluster_share_path` |
| `minecraft.dns_name` | `mc` | Players connect to `<dns_name>.<cluster_domain>` |
| `minecraft.worlds.node` | *(node name)* | Node all worlds are pinned to — the VPS relay forward target |
| `minecraft.worlds.port_min` / `port_max` | `30565` / `30584` | Inclusive NodePort range for game ports |
| `minecraft.worlds.rcon_port_min` / `rcon_port_max` | `30600` / `30619` | Inclusive NodePort range for per-world RCON (LAN only; never relay it) |
| `minecraft.worlds.rcon_allowed_cidrs` | LAN CIDRs | Sources allowed to reach world RCON through the dashboard's NetworkPolicy (CIDR or `{cidr, except}`); except every cluster node's IP other than the world node and RCON-client workstations, since pods on other nodes arrive as their node's IP |
| `enable_vps_relay` | `true` | Deploy the VPS relay ({doc}`/how-to/vps-relay`); needs the `vps-relay-credentials` SealedSecret |
| `vps_relay.vps_tailnet_host` | *(tailnet IP or name)* | The VPS's tailnet IP or MagicDNS name, where frps listens |
| `vps_relay.frp_port` | `7000` | frps control port on the VPS's tailnet address |
| `vps_relay.forwards` | *(minecraft entry)* | List of `name`, `protocol` (`tcp`/`udp`), `ports` (port or `min-max`) and `target`; each publishes `ports` on the VPS and relays them to the same ports on `target`. The VPS's `allowPorts` and firewall must match |

The root Application passes `repo_branch` in from Ansible, so the copy in values.yaml is
only a default; switch branches with `just switch-branch <branch>`.

The `nfs.*` values feed the static backup, Minecraft and scrap volumes and Jellyfin's
media, and the `etcd_backup`
role reads them from `values.yaml` for its NAS mount. The `nfs_csi.*` values configure
the dynamic NFS StorageClasses separately.

## Environment variables

| Variable | Set in | Description |
|----------|--------|-------------|
| `BIN_DIR` | `devcontainer.json` | Directory for CLI tools (`/root/bin`) |
| `ZSHRC` | `devcontainer.json` | Path to zsh config |
| `ANSIBLE_VAULT_PASSWORD_FILE` | `devcontainer.json` | Vault password file path |
