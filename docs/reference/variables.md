# Variables reference

Every setting this cluster is built from, with the value it has today. Ansible
reads `group_vars/all.yml`, `hosts.yml` and each role's `vars/` or `defaults/`;
ArgoCD reads `kubernetes-services/values.yaml`. A few settings exist in both
worlds and must agree: they are marked **SYNC** here and in the files.

## Global variables (`group_vars/all.yml`)

| Variable | Value | Description |
|----------|-------|-------------|
| `ansible_account` | `ansible` | The account Ansible uses on every node (created by the RK1 cloud-init seed, or by `pb_add_nodes.yml`) |
| `tpi_user` | `root` | SSH user on the Turing Pi BMC |
| `tpi_images_path` | `/mnt/sdcard/images` | Where OS images are staged on the BMC's SD card before `tpi flash` |
| `bin_dir` | `/root/bin` (from `$BIN_DIR`; `$HOME/bin` without it) | Where the `tools` role installs helm, kubectl, kubeseal, hubble, argocd and the port-forward scripts: a volume, so it survives a devcontainer rebuild |
| `k3s_minor` | `v1.34` (read from `k3s.minor` in `values.yaml`) | The K3s minor line the cluster follows. Edit it in `values.yaml`, not here |
| `do_flash` | `false` | Whether the `flash` role runs; true when `flash_force` (or `force_flash`) is passed, or set directly with `-e do_flash=true` |
| `local_domain` | `.lan` | Suffix the `known_hosts` role adds to a node name to look up its addresses |
| `known_hosts_files` | `~/.ssh/known_hosts`, `/etc/ssh/ssh_known_hosts` | Files the `known_hosts` role keeps current. The system-wide one is what claude-sandbox reads, as its `$HOME` is a fresh tmpfs |
| `control_plane` | `node02` | The (single) control plane node |
| `standby_control_plane` | `node03` | Warm-standby control plane: the node a restore goes onto ({doc}`/how-to/recover-control-plane`). The `cluster` tag taints it `node-role.kubernetes.io/standby-control-plane:PreferNoSchedule` and removes that taint from any other node. Empty for none |
| `k3s_api_name` | `k3s.lan` | Stable DNS name for the Kubernetes API, a record on the router that resolves to the control plane. Agents join it, it is a `tls-san` on the server certificate and the kubeconfig uses it, so moving the control plane means changing `control_plane` and this record. Every address it resolves to must be the control plane's |
| `dns_router` | `root@192.168.1.1` | SSH target (`user@host`) of the OpenWrt router (dnsmasq, `uci`). Used by `just k3s-api-dns <ip>` to point `k3s_api_name` at the control plane, by the control plane's daily router backup (`etcd_backup_router`) and by `pb_router.yml --tags restore` ({doc}`/how-to/router-recovery`) |
| `etcd_backup_age_recipient` | *(age public key)* | The key the nightly etcd backup is encrypted to; the private key is kept offline. Empty makes the backup fail without uploading. **SYNC:** `offsite_backup.age_recipient` (`scripts/check-age-recipient`, run by `just check`, fails if they differ) |
| `cluster_domain` | `gkcluster.org` | Domain of every ingress host |
| `domain_email` | *(an address)* | Let's Encrypt registration address for cert-manager |
| `admin_emails` | *(list)* | GitHub-linked addresses mapped to ArgoCD admin in the Ansible-rendered ArgoCD config. **SYNC:** `admin_emails` in `values.yaml` |
| `repo_remote` | `https://github.com/gilesknap/tpi-k3s-ansible.git` | The repo ArgoCD deploys from |
| `repo_branch` | `main` | The branch ArgoCD tracks. The root Application passes it to every child app ({doc}`/how-to/work-in-branches`) |
| `nvidia_gpu_node`, `intel_gpu_node` | `false` | Defaults for the per-node GPU flags below |
| `cluster_install_list` | `[argocd]` | What the `cluster` role installs itself; everything else is ArgoCD's |
| `k8s_data_dirs` | prometheus and grafana on `node04` (`/var/lib/k8s-data/...`); scrap-backup-copy and jellyfin on `nuc2` (`/home/k8s-data/...`) | Host directories behind the `local-nvme` PVs, each with `node`, `path`, `owner`, `group` and `mode`. The `k8s_data_dirs` role creates them and never deletes one. **SYNC:** `node` and `path` with `local_storage` in `values.yaml` |

## Role-specific variables

### Host variables (`hosts.yml`)

Set per host: `slot_num`, `type`, `root_dev`, `nvidia_gpu_node`,
`intel_gpu_node`, `workstation` and `node_ip`. They are
described, with the values each node has, in {doc}`/reference/inventory`.

### `tools` role (`roles/tools/vars/main.yml`)

| Variable | Value | Description |
|----------|---------|-------------|
| `tools_zshrc` | `/bash-config/zshrc` (from `$ZSHRC`) | The zsh rc file the role adds `PATH` and the `k` alias to |
| `tools_bashrc` | `~/.bashrc` (or `$BASHRC`) | The bash rc file, likewise |
| `tools_shell` | bash, zsh | Each shell's rc file and completion directory |
| `tools_additional_packages` | `iputils-ping`, `net-tools`, `dnsutils`, `vim`, `sshpass` | Listed for the devcontainer; no task in the role installs from it today (the Dockerfile provides `dnsutils`) |

### `flash` role (`roles/flash/vars/main.yml`)

| Variable | Value | Description |
|----------|---------|-------------|
| `flash_force` | `false` | Re-flash a node even if it answers SSH; on an RK1 with `root_dev`, also the only way to wipe an NVMe that has a partition table |
| `flash_local_tmp` | `/tmp/iac2` | Directory in the devcontainer for downloaded OS images |
| `flash_pre_flashed` | `false` | Debugging flag: skip the flash step itself |
| `flash_rp4_vers`, `flash_image_info` | `24.04.4` (pinned) | Ubuntu image for a CM4 (`type: pi4`): URL and sha256 |
| `flash_rk1_uboot_deb`, `flash_rk1_uboot_deb_file` | (pinned) | Armbian's mainline U-Boot package for the RK1: URL, sha256, and the path and sha256 of `u-boot-rockchip.bin` in it |
| `flash_rk1_os_vers`, `flash_rk1_os_image` | `26.04.1` (pinned) | Ubuntu's preinstalled server image for the RK1: URL and sha256, and the decompressed image's sha256 and size, which the install checks on the NVMe |
| `flash_rk1_emmc_sha256` | (pinned) | sha256 of the uncompressed eMMC staging image built from the two above |
| `flash_rk1_cache_dir` | `{{ flash_local_tmp }}/rk1` | Controller cache for the RK1 downloads and the built image (about 6 GB at the peak of a build) |
| `flash_seed_ssh_keys` | ansible key (+ Claude key) | Keys authorised for the `ansible` account by the RK1 cloud-init seed |

### `k3s` role (`roles/k3s/vars/main.yml`)

| Variable | Value | Description |
|----------|---------|-------------|
| `k3s_force` | `false` | Reinstall K3s on the targeted nodes (uninstalling first) |
| `k3s_install_occurred` | `false` | Internal: set when any node had K3s installed in this run |
| `k3s_version` | unset | Exact release to install (e.g. `v1.34.6+k3s1`), on the `k3s_minor` line. Unset: the control plane takes the channel's newest patch and workers the control plane's version. |

### `etcd_backup` role (`roles/etcd_backup/defaults/main.yml`)

| Variable | Value | Description |
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
| `etcd_backup_router` | `dns_router` | SSH target of the router whose `sysupgrade -b` backup a second timer, `router-backup.timer`, encrypts to the same recipient; empty for none ({doc}`/how-to/router-recovery`) |
| `etcd_backup_router_dest_subdir` | `backups/router` | Its destination below the mount point |
| `etcd_backup_router_keep` | `30` | Router backups kept on the NAS |
| `etcd_backup_router_on_calendar` | `*-*-* 23:00:00 Europe/London` | Its systemd `OnCalendar` schedule |
| `etcd_backup_router_key` / `etcd_backup_router_known_hosts` | `/etc/k3s-etcd-backup/router_ed25519` / `router_known_hosts` | The job's SSH key, made on the control plane, and the router's pinned host key |

### `nas` role (`roles/nas/defaults/main.yml`)

Used by `pb_nas.yml` only ({doc}`/how-to/nas-ubuntu-zfs`). The defaults file
documents each one; these are the ones a rebuild touches.

| Variable | Value | Description |
|----------|-------|-------------|
| `nas_pool` / `nas_pool_disks` | `tank` / by-id paths of the two SSDs | The main pool, a mirror. The disks must be `/dev/disk/by-id/` paths |
| `nas_backup_pool` / `nas_backup_pool_disks` | `backup` / by-id path of the LaCie | The backup pool, which receives a nightly copy of every dataset; optional |
| `nas_create_pool`, `nas_create_backup_pool`, `nas_force` | `false` | Command-line only. Create the pool (destroying the disks' contents); `nas_force` also allows disks that are not blank |
| `nas_datasets` | `tank/bigdisk` (`/bigdisk`) and its children, `tank/k8s-dynamic`, `tank/Minecraft` | Datasets and their properties; their mountpoints are the paths the cluster mounts |
| `nas_directories` | The cluster's tree | Directories created inside the datasets with their owner and mode: each backup directory owned by its one writer, `0755` ({doc}`/how-to/nas-ubuntu-zfs`) |
| `nas_nfs_clients` | The nodes and `ws03`, by IP | The only hosts the exports admit. **SYNC:** `hosts.yml` |
| `nas_nfs_exports` | One per dataset | Path and export options; `/bigdisk` and its children squash root, `/k8s-dynamic` does not (as on QTS). Optional `clients` narrows the hosts, `read_only_for` makes it read-only to some (`/bigdisk`, `Photos-Archive` (read-only), `/Minecraft`: `ws03` only; `k8s-cluster`: the nodes only; `media`: read-only to the nodes) |
| `nas_snapshot_retention` / `nas_backup_retention` | 48 hourly, 30 daily, 8 weekly, 12 monthly / 60 daily, 24 monthly | sanoid's retention on the main pool and on the backup pool. `weekly` on the main pool must be at least 1 while any dataset is held |
| `nas_hold_tag` / `nas_hold_datasets` | `nas-keep` / every dataset of `tank` in `nas_datasets` | The ZFS hold kept on the newest weekly snapshot of each dataset, against an accidental destroy ({doc}`/how-to/nas-ubuntu-zfs`) |
| `nas_hold_on_calendar` | `*-*-* 02:00:00 Europe/London` | When `nas-hold` moves the holds to the newest weeklies (daily; sanoid takes them Mondays at 23:30) |
| `nas_replicate_on_calendar` | `*-*-* 06:30:00 Europe/London` | When the nightly copy to the backup pool runs |
| `nas_netplan_ethernets` | `enp3s0` and `enp2s0`, both DHCP, `enp2s0` optional | The NAS's network ports, as netplan `ethernets`; the port not cabled is `optional`, so boot does not wait for it |
| `nas_qnap_ec_driver` | `true` | Build the community `qnap8528` EC driver (fans, temperatures) with DKMS, at `nas_qnap_ec_commit` |

### `update_packages` and `node_reboot` roles (`defaults/main.yml`)

| Variable | Value | Description |
|----------|-------|-------------|
| `update_packages_upgrade_on_calendar` | `*-*-* 00:00 Europe/London` | When unattended-upgrades runs each night: before the K3s upgrade and kured windows, so a new kernel is rebooted into the same night |
| `update_packages_upgrade_random_delay` | `30m` | Random delay added to that time |
| `node_reboot_msg` | `Rebooting by Ansible` | Message logged by a reboot |
| `node_reboot_timeout` | `900` | Seconds to wait for a rebooted node to come back |

### `rk1_os` role (`defaults/main.yml`, `vars/main.yml`)

The role converts an RK1 still on the old ubuntu-rockchip vendor layout to
stock Ubuntu; all three RK1s are converted, so it now finds nothing to do.

| Variable | Value | Description |
|----------|-------|-------------|
| `rk1_os_target_release` | `26.04` | The release every RK1 ends on |
| `rk1_os_kernel_packages` | `linux-generic` on 26.04 | Kernel metapackage per release |
| `rk1_os_cmdline` | console on `ttyS9` and `tty1`, cgroup flags | Kernel command line GRUB boots with |
| `rk1_os_grub_timeout` | `3` | Seconds the GRUB menu waits (visible on `tpi uart`) |
| `rk1_os_vendor_packages`, `rk1_os_vendor_extra_packages` | *(lists)* | Packages purged once the node is on the target release |
| `rk1_os_keep_packages`, `rk1_os_protected_packages` | *(lists)* | Packages marked manual before the purge, and those whose removal stops it |

## Command-line overrides

Passed with `-e` to `ansible-playbook`. None of them is stored anywhere: each
applies to that run only.

| Override | Playbook | Effect |
|----------|----------|--------|
| `-e do_flash=true` | `pb_all.yml` | Run the `flash` role: flashes any Turing Pi node that does not answer SSH |
| `-e flash_force=true` | `pb_all.yml` | Also re-flash nodes that do answer, and allow the wipe of an RK1 NVMe that has a partition table. Use with `--limit turingpi,<node>` |
| `-e k3s_force=true` | `pb_all.yml` | Uninstall and reinstall K3s on the targeted nodes |
| `-e k3s_version=v1.34.13+k3s1` | `pb_all.yml` | Install that exact release; it must be on the `k3s_minor` line |
| `-e reboot_now=true` | `pb_all.yml` | After `update_packages`, drain and reboot each node that needs it, one at a time, instead of leaving it to kured. Never reboots a workstation |
| `-e repo_branch=<branch>` | `pb_all.yml --tags cluster` | Point ArgoCD at a branch (what `just switch-branch` does) |
| `-e claude_pubkey_state=absent` | `pb_all.yml --tags claude_key` | Remove the Claude sandbox key from the nodes instead of adding it |
| `-e claude_ansible_pubkey_path=<path>` | `pb_all.yml` | Use a different public key file than `/root/.config/claude-ssh/id_ed25519.pub` |
| `-e '{"known_hosts_files": ["~/.ssh/known_hosts"]}'` | `pb_all.yml` | Skip the system-wide known_hosts file when not running as root |
| `-e ansible_user=<user> -K` | `pb_add_nodes.yml` | The existing sudo-capable account on a machine that has no `ansible` account yet |
| `-e wipe_local_data=true` | `pb_decommission.yml` | Also delete `/home/k8s-data` and `/var/lib/k8s-data`: every `local-nvme` PV's data. Destructive |

(argocd-helm-values)=
## ArgoCD Helm values (`kubernetes-services/values.yaml`)

| Variable | Value | Description |
|----------|---------|-------------|
| `repo_branch` | `main` | Branch for child ArgoCD Applications' `targetRevision` |
| `k3s.minor` | `v1.34` | The K3s minor line. system-upgrade-controller follows its release channel, so patch releases arrive on their own; changing it is the deliberate minor upgrade ({doc}`/how-to/upgrade-k3s`). The `k3s` role reads it too |
| `k3s.upgrade_window` | every day, `01:00` to `02:00`, `Europe/London` | When system-upgrade-controller may start a round of K3s upgrades |
| `kured.start_time` / `end_time` / `time_zone` | `02:30` / `05:00` / `Europe/London` | The window in which kured reboots nodes that need it, one at a time ({doc}`/explanations/upgrade-model`) |
| `headlamp.argocd_plugin.enabled` / `version` / `sha256` | `true` / `0.1.0-alpha` / *(checksum)* | The Argo CD plugin an init container unpacks into Headlamp; bump `version` and `sha256` together |
| `enable_oauth2_proxy` | `true` | Put oauth2-proxy in front of the protected routes ({doc}`/explanations/architecture/authentication`). `false` leaves them open, which is only for the first hours of a build, before the OAuth credentials are sealed ({doc}`/how-to/oauth-setup`) |
| `enable_cloudflare_tunnel` | `true` | Turn off the Gateway's HTTPS redirect on tunnelled services, since Cloudflare terminates TLS at its edge and a redirect would loop ({doc}`/how-to/cloudflare-as-code`) |
| `cf_access_team` | *(team name)* | The Cloudflare Zero Trust team (`<team>.cloudflareaccess.com`); used by the `/test-oauth-flow` command to build the Access logout URL |
| `admin_emails` | *(list)* | GitHub-linked addresses with admin rights: Grafana Admin, and the only addresses oauth2-proxy lets through. ArgoCD admin comes from the copy in `group_vars/all.yml`. **SYNC:** that copy |
| `nfs.server` | `192.168.1.3` | The NAS: NFS server for the static backup, Minecraft, scrap and media volumes |
| `nfs.cluster_share_path` | `/bigdisk/k8s-cluster` | The cluster-owned directory on the NAS ({doc}`/how-to/nas-setup`) |
| `nas.monitoring.enabled` / `nas.monitoring.targets` | `true` / `[192.168.1.3:9100]` | Scrape the NAS's node-exporter (job `nas`) and load the NAS alerts ({doc}`/how-to/nas-ubuntu-zfs`) |
| `nfs_csi.server` | `192.168.1.3` | NFS server for the dynamic StorageClasses (the NAS again) |
| `nfs_csi.share` | `/k8s-dynamic` | Export for `nfs-rwx` scratch volumes (a new folder per PV) |
| `nfs_csi.stable_share` | `/k8s-dynamic/stable` | Folder for `nfs-stable` volumes (one fixed folder per PVC); keep it a subfolder of `share` |
| `nfs_csi.chart_version` | `4.13.4` | csi-driver-nfs chart version |
| `nfs_csi.fresh_storage_class` | `nfs-rwx` | Name of the scratch StorageClass, used only when named |
| `nfs_csi.stable_storage_class` | `nfs-stable` | Name of the default StorageClass |
| `enable_jellyfin` | `true` | Deploy Jellyfin ({doc}`/how-to/jellyfin`); needs `local_storage.jellyfin` and its `k8s_data_dirs` entry |
| `jellyfin.chart_version` / `image_tag` | `3.7.0` / `12.4.20261026-211555` | The upstream chart version and the Jellyfin image tag (never older than the database's Jellyfin) |
| `jellyfin.trial` | `false` | Throwaway trial config: marks the config volume `TRIAL-CONFIG-SAFE-TO-DELETE`. Not with `seed_from_host` |
| `jellyfin.seed_from_host` | `false` | One-off copy of the stopped host install on `nuc2` into the config volume (init containers). Off now that the seed is done: the volume is marked `SEEDED-FROM-HOST` |
| `jellyfin.seed.sqlite_image` | `docker.io/keinos/sqlite3:3.54.1` | Image with `sqlite3`, for the seed's integrity check and the backup CronJobs |
| `jellyfin.seed.hardware_decoding_codecs` | `[h264, hevc, …]` | Replaces `HardwareDecodingCodecs` in the copied `encoding.xml`; empty leaves it unchanged |
| `jellyfin.data_dir` / `config_dir` / `log_dir` / `cache_dir` | `/var/lib/jellyfin` / `/etc/jellyfin` / `/var/log/jellyfin` / `/var/cache/jellyfin` | Jellyfin's paths in the pod, the same as a host install's. The first three are the config volume's `data/`, `config/` and `log/`; the seed copies the host's `data_dir` and `config_dir` |
| `jellyfin.cache_size` | `20Gi` | Size limit of the emptyDir for the cache and transcodes |
| `jellyfin.host_network` | `true` | Run on the node's network (both LANs, Tailscale, UDP 7359 discovery); off for a trial beside a host install |
| `jellyfin.uid` / `gid` | `122` / `124` | The node's `jellyfin` account; must match the `k8s_data_dirs` owner |
| `jellyfin.render_gid` / `video_gid` | `992` / `44` | The node's `render` and `video` groups, for `/dev/dri` |
| `jellyfin.media.nfs_path` / `mount_path` | `/bigdisk/media` / `/media/bigdisk/media` | The library's NFS export on `nfs.server`, and where the pod mounts it read-only |
| `offsite_backup.enabled` | `true` | Nightly off-site copy of the NAS backups to Google Drive ({ref}`offsite-backup`). It needs the sealed rclone credentials (`just seal-rclone-drive`), and its alerts fire only while it is on. It gates the B2 copy too: off, neither job exists |
| `offsite_backup.schedule` / `time_zone` | `30 5 * * *` / `Europe/London` | When it runs: after the other nightly backups |
| `offsite_backup.drive_root` | `home-cluster-offsite` | Folder in the Drive's root that everything goes into |
| `offsite_backup.include` | `[backups, minecraft-nightly, minecraft-archive]` | What goes to Drive: the NAS `backups/` tree, the nightly Minecraft tarball, the world archive |
| `offsite_backup.b2.enabled` | `true` | The second off-site copy, to a Backblaze B2 bucket with Object Lock ({ref}`offsite-b2`). Needs `offsite_backup.enabled` too. Turn on only after the one-time B2 setup and `just seal-b2-offsite`; its alerts fire only while it is on |
| `offsite_backup.b2.bucket` | `gk-cluster-offsite` | The bucket's name; required when `b2.enabled` |
| `offsite_backup.b2.secret_name` | `offsite-backup-b2` | The Secret holding rclone's `[b2]` remote |
| `offsite_backup.b2.include` | `[backups]` | What goes to B2, from the same three as `include`: only the NAS backups, which keeps the bucket inside B2's free 10 GB |
| `offsite_backup.age_recipient` | *(age public key)* | age public key every file is encrypted to. **SYNC:** `etcd_backup_age_recipient` |
| `offsite_backup.image` | `docker.io/rclone/rclone:1.75.2` | rclone image (Alpine, busybox) every container runs |
| `offsite_backup.age.version` / `sha256.amd64` / `sha256.arm64` | `1.3.2` / *(checksums)* | age release an init container fetches, checked against these checksums; bump all three together |
| `offsite_backup.deadline_hours` | `6` | A run is stopped after this long; the next carries on |
| `offsite_backup.backups.uid` | `65534` | User the `backups` container runs as: the NAS's squashed-root owner of the etcd bundles. It uploads everything under `backups/` but the `run_dirs` |
| `offsite_backup.backups.run_dirs` | `[scrap, scrap/monthly, scrap-curated]` | Folders under `backups/` whose subfolders are runs, each uploaded by the `scrap` container as one tarball once complete (`<run>.incomplete.tar.age` if it has no `COMPLETE` marker once its folder is two days old) |
| `offsite_backup.backups.exclude` | `etcd/LATEST`, `etcd/sealed-secrets-keys.yaml.age{,.sha256}` | Paths under `backups/` rewritten in place, never uploaded |
| `offsite_backup.backups.prune_days` / `keep_min` | `180` / `4` | Delete a file on Drive only once its source is gone from the NAS and it was uploaded over `prune_days` ago (`0`: never), always keeping the `keep_min` newest of each series |
| `offsite_backup.scrap.uid` / `gid` | `10001` / `10001` | User the `scrap` container runs as: scrap's, as hard-coded in `additions/scrap/templates/backup-copy.yaml`, which owns its backup runs' files |
| `offsite_backup.minecraft.enabled` | `true` | Also upload the Minecraft store, worlds and archive (only with `enable_minecraft`) |
| `offsite_backup.minecraft.uid` / `gid` | `1000` / `1000` | User the `minecraft` container runs as: the owner of the worlds' files |
| `offsite_backup.minecraft.worlds_path` | `""` (`nfs_csi.stable_share`) | Share whose `minecraft/` (live worlds) and `archived-minecraft/` (deleted worlds) folders go in the nightly tarball |
| `offsite_backup.minecraft.keep` | `7` | Nightly Minecraft tarballs kept on Drive |
| `offsite_backup.minecraft.min_size_percent` | `50` | A nightly tarball smaller than this percentage of the largest on Drive fails the run and stops pruning |
| `offsite_backup.minecraft.archive` | `true` | Upload `minecraft.archive_path` (once, and again only if it changes) |
| `enable_minecraft` | `true` | Deploy the Minecraft dashboard ({doc}`/how-to/minecraft`) |
| `minecraft.chart_version` | `0.5.2` | Version of the `ghcr.io/gilesknap/charts/minecraft-dashboard` OCI chart (image tag follows the chart's appVersion) |
| `minecraft.image.repository` | `ghcr.io/gilesknap/k3s-minecraft` | The dashboard image |
| `minecraft.archive_path` | `/bigdisk/minecraft-archive` | Read-only NFS path of the world archive on `nfs.server` (outside the cluster share) |
| `minecraft.store_subdir` | `minecraft` | Writable store directory under `nfs.cluster_share_path` |
| `minecraft.dns_name` | `mc` | Players connect to `mc.gkcluster.org`, a DNS-only record for the VPS relay |
| `minecraft.worlds.node` | `nuc2` | Node all worlds are pinned to: the VPS relay forward's target |
| `minecraft.worlds.port_min` / `port_max` | `30565` / `30584` | Inclusive NodePort range for game ports |
| `minecraft.worlds.rcon_port_min` / `rcon_port_max` | `30600` / `30619` | Inclusive NodePort range for per-world RCON (LAN only; never relay it) |
| `minecraft.worlds.rcon_allowed_cidrs` | `192.168.1.0/24` except the other nodes, and `192.168.0.0/24` | Sources allowed to reach world RCON through the dashboard's NetworkPolicy (CIDR or `{cidr, except}`); except every cluster node's IP other than the world node and RCON-client workstations, for node traffic that arrives from a LAN address (through Cilium's tunnel it carries a node identity, which no CIDR matches) |
| `minecraft.worlds.rcon_allowed_nodes` | `[ws03]` | Nodes (by `kubernetes.io/hostname`) whose hosts may reach world RCON, through the `minecraft-rcon-nodes` CiliumNetworkPolicy (`fromNodes`); their connections arrive from their Cilium address, which no CIDR matches |
| `enable_vps_relay` | `true` | Deploy the VPS relay ({doc}`/how-to/vps-relay`); needs the `vps-relay-credentials` SealedSecret |
| `vps_relay.vps_tailnet_host` | *(tailnet address)* | The VPS's tailnet IP or MagicDNS name, where frps listens |
| `vps_relay.frp_port` | `7000` | frps control port on the VPS's tailnet address |
| `vps_relay.forwards` | `minecraft`: tcp `30565-30584` to `192.168.1.92` | List of `name`, `protocol` (`tcp`/`udp`), `ports` (port or `min-max`) and `target`; each publishes `ports` on the VPS and relays them to the same ports on `target`. The VPS's `allowPorts` and firewall must match |
| `enable_kyverno` / `kyverno.chart_version` | `false` / `3.9.1` | Kyverno is off: the app never settled to Synced on its CRDs, and no policies were in use |
| `local_storage.<name>` | `grafana` and `prometheus` on `node04`; `scrap_backup_copy` and `jellyfin` on `nuc2` | One static `local-nvme` PV each: `node`, `path`, `capacity` and the `claim_namespace`/`claim_name` it is pre-bound to ({doc}`/explanations/architecture/storage`). **SYNC:** `k8s_data_dirs` |

The root Application passes `repo_branch` in from Ansible, so the copy in values.yaml is
only a default for `helm template` runs; switch branches with
`just switch-branch <branch>`.

The `nfs.*` values feed the static backup, Minecraft and scrap volumes, Jellyfin's
media and the off-site backup's mounts, and the `etcd_backup`
role reads them from `values.yaml` for its NAS mount. The `nfs_csi.*` values configure
the dynamic NFS StorageClasses separately.

## Environment variables

Set for the devcontainer by `.devcontainer/devcontainer.json`:

| Variable | Value | Description |
|----------|-------|-------------|
| `BIN_DIR` | `/root/bin` | Becomes `bin_dir`: the `iac2-bin` volume the CLIs are installed into |
| `ZSHRC` | `/bash-config/zshrc` | The zsh rc file the `tools` role edits |
| `UV_*`, `VIRTUAL_ENV`, `PRE_COMMIT_HOME` | under `/cache` | Keep the Python environment and caches on a persistent volume |

Read by the scripts. Each is optional unless marked; a script that needs a
secret prompts for it when the variable is unset.

| Variable | Read by | Description |
|----------|---------|-------------|
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | `scripts/generate-secrets` (required) | The Dex GitHub OAuth app |
| `OAUTH2_PROXY_CLIENT_ID`, `OAUTH2_PROXY_CLIENT_SECRET` | `generate-secrets` (required) | The oauth2-proxy GitHub OAuth app |
| `CLOUDFLARE_API_TOKEN` | `generate-secrets` (required) | cert-manager's DNS-01 token ({ref}`cf-dns01-token`) |
| `CLOUDFLARE_TUNNEL_TOKEN` | `generate-secrets` (required) | cloudflared's tunnel token; `scripts/cf-seal-tunnel-token` also updates it in `.env` |
| `ADMIN_PASSWORD` | `generate-secrets`, `scripts/set-admin-password` | The shared admin password; generated, or prompted for, if unset |
| `VPS_RELAY_TS_OAUTH_CLIENT_SECRET`, `VPS_RELAY_FRP_TOKEN` | `generate-secrets` | The VPS relay's Tailscale OAuth client secret and frp token: both or neither |
| `SCRAP_ANTHROPIC_API_KEY` | `generate-secrets` | Claude API key for scrap's ingest; scrap's secrets are sealed only if it is set |
| `SCRAP_MCP_TOKEN`, `SCRAP_PUBLISH_TOKEN` | `generate-secrets` | Kept as given, since clients hold copies; generated if unset |
| `SCRAP_MCP_TOKEN_CANARY` | `generate-secrets` | The claude-canary VPS's own `/mcp` token; kept as given, never generated (unset: none) |
| `SCRAP_ROTATE_MCP_TOKEN` | `generate-secrets` | `true` replaces `SCRAP_MCP_TOKEN` with a new one |
| `OFFSITE_BACKUP_RCLONE_CONF_B64` | `generate-secrets` | The off-site backup's `rclone.conf`, base64-encoded; resealed as given |
| `OFFSITE_BACKUP_B2_RCLONE_CONF_B64` | `generate-secrets` | The B2 off-site copy's `rclone.conf` (its application key), base64-encoded; resealed as given |
| `NTFY_<USER>_TOKEN` | `generate-secrets` | One per ntfy user in `scripts/lib/ntfy_auth.py` (for example `NTFY_PHONE_TOKEN`); kept as given, generated if unset |
| `TF_VAR_state_passphrase` | `scripts/cf-tofu` | OpenTofu state passphrase; else `cloudflare/.secrets/state-passphrase`, else a prompt |
| `CF_PLAN_TOKEN` | `cf-tofu plan` | Read-only Cloudflare token; else `cloudflare/.secrets/plan-token`, else a prompt |
| `CF_APPLY_TOKEN` | `cf-tofu apply`, `scripts/cf-tunnel-disconnect` | Edit token; else a prompt. Never read from a file |
| `DRY_RUN`, `FORCE` | `scripts/restore-control-plane` | `DRY_RUN=1` prints what would run; `FORCE=1` skips the second confirmation |
| `IMAGE`, `BACKUP_DIR` | `scripts/nfs-stable-paths` | The Jobs' image, and where the PVC and PV manifests are saved first |
| `FRP_PORT` | `scripts/vps-relay-setup` (on the VPS) | frps control port, default `7000`. **SYNC:** `vps_relay.frp_port` |

`just export-external-creds` (`scripts/export-external-creds`) writes every
`generate-secrets` variable above except `ADMIN_PASSWORD` and
`SCRAP_ROTATE_MCP_TOKEN` from the live cluster's Secrets into `.env` at the repo
root (gitignored), ready for a rebuild: `set -a && source .env && set +a`.
