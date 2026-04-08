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

### `cluster` role (`roles/cluster/vars/main.yml`)

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_force` | `false` | Force ArgoCD reinstall |
| `cluster_longhorn_version` | (version string) | Longhorn chart version (legacy, now in template) |

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
| `viewer_emails` | *(list of emails)* | GitHub-linked email addresses with read-only access to Dex-authenticated services |
| `rkllama.nfs.server` | *(your NFS server IP)* | NFS server for RKLLama model storage |
| `rkllama.nfs.path` | *(your NFS export path)* | Exported NFS path for RKLLama models (`.rkllm` files) |
| `llamacpp.nfs.server` | *(your NFS server IP)* | NFS server for llama.cpp model storage |
| `llamacpp.nfs.path` | *(your NFS export path)* | Exported NFS path for llama.cpp models (GGUF files — keep separate from rkllama) |
| `llamacpp.model.file` | *(GGUF filename)* | Filename of the GGUF model to load at startup |
| `llamacpp.model.gpuLayers` | `99` | Transformer layers to offload to GPU (`99` = all) |
| `llamacpp.model.contextSize` | `8192` | KV-cache context length in tokens |
| `llamacpp.model.parallel` | `4` | Concurrent request slots |
| `llamacpp.model.memoryLimit` | `24Gi` | Kubernetes memory limit for the container |

The `repo_branch` value is self-referential — ArgoCD reads it from the same branch it
is tracking. Each branch must set this to match its own branch name.

The `rkllama.nfs.*` values are the **single source of truth** for NFS configuration.
ArgoCD injects them directly into the rkllama Helm chart; no corresponding Ansible
variable is needed because Ansible does not create the PersistentVolume.

## Environment variables

| Variable | Set in | Description |
|----------|--------|-------------|
| `BIN_DIR` | `devcontainer.json` | Directory for CLI tools (`/root/bin`) |
| `ZSHRC` | `devcontainer.json` | Path to zsh config |
| `ANSIBLE_VAULT_PASSWORD_FILE` | `devcontainer.json` | Vault password file path |
