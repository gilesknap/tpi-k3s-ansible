---
name: bootstrap-cluster
description: Interactively bootstrap a K3s cluster from scratch — configure inventory, generate secrets, run playbooks, and produce a credentials file.
user_invocable: true
---

# Bootstrap Cluster

Guide the user through setting up a K3s cluster from scratch. Ask questions
interactively, configure files, generate secrets, run playbooks, and write a
credentials summary file.

## Important rules

- **Never commit or push** without asking the user first.
- **Never `kubectl apply/patch/edit`** except for `kubeseal` (used internally
  by `GENERATE_SECRETS=true`).
- Use `uv run` for any git commits (pre-commit hooks need the uv venv).
- Run `ansible-playbook` commands from within the devcontainer.

## Topology-aware constraints

After gathering hardware info, apply these rules automatically. Inform the
user what was decided and why — don't silently skip features.

### Node count rules

| Nodes | Control plane taint | Longhorn | Cloudflared replicas |
|-------|---------------------|----------|----------------------|
| 1     | **Disabled** (workloads must run on control plane) | Replica count **1** (no redundancy — warn user) | **1** |
| 2     | **Offer as option** (default: disabled) | Replica count **2** (warn: no full redundancy) | **2** |
| 3+    | **Enabled by default** | Replica count **3** (default) | **2** |

When Longhorn replica count is reduced, edit `kubernetes-services/templates/longhorn.yaml`
and change `defaultClassReplicaCount` from 3 to the appropriate value.

### Hardware-gated features

Only **offer** these features if the cluster has the required hardware.
If the hardware is absent, tell the user the feature is unavailable and why.

| Feature | Requirement | Reason |
|---------|-------------|--------|
| **Open Brain (Supabase)** | At least one **x86/amd64** node | Container images lack reliable ARM64 support |
| **RKLLama** | At least one **RK1** node (`type: rk1`) | Needs Rockchip NPU (`/dev/rknpu`) |
| **llama.cpp** | A node with **NVIDIA GPU** (`nvidia_gpu_node: true`) | Needs CUDA for inference |
| **NFS storage** | Only ask if user wants **rkllama or llamacpp** | NFS is only used for LLM model storage |

### Single-node cluster notes

Single-node clusters work fine — K3s runs as both control plane and worker.
Warn the user about these trade-offs:
- No storage redundancy (Longhorn replica count 1)
- No high availability (single point of failure)
- All workloads compete for the same node's resources

## Phase 1: Gather information

Ask the user the following questions **one group at a time** (don't overwhelm
with all questions at once). Use sensible defaults where noted.

### Hardware

1. **Are you using Turing Pi boards?** (yes/no)
   - If yes: How many boards? How many nodes per board? What types (RK1/CM4)?
     Which slots? NVMe drives?
   - If no: How many Linux servers? Hostnames or IPs? Which is the control plane?
     What architecture are they? (x86/ARM/mixed)

2. **Do any nodes have an NVIDIA GPU?** (yes/no, which node?)

After these answers, calculate total node count, available architectures, and
which hardware-gated features can be offered.

### Cluster personalisation

3. **Domain name** for the cluster (e.g. `mycluster.example.com`)
4. **Email address** for Let's Encrypt certificates
5. **GitHub fork URL** (e.g. `https://github.com/<user>/tpi-k3s-ansible.git`)
6. **Git branch** to track (default: `main`)

### Optional features

Only present features the hardware supports (see constraints above).

7. **Control plane taint?** (skip for 1 node, offer for 2, default yes for 3+)
8. **NFS server?** — Only ask if rkllama or llamacpp is possible.
   If yes, IP and export paths for LLM models.
9. **OAuth2 proxy?** (yes/no, default: no — enable later)
10. **Cloudflare tunnel?** (yes/no, default: no — enable later)
11. **Open Brain (Supabase)?** — Only if x86 node exists. (default: no — enable later)
12. **RKLLama?** — Only if RK1 nodes exist.
13. **llama.cpp?** — Only if NVIDIA GPU node exists.

## Phase 2: Configure files

Based on answers, edit these files (read each before editing):

### `hosts.yml`
- For Turing Pi: configure `turing_pis`, `turingpi_nodes` groups with slot
  numbers, types, and optional `root_dev`
- For generic servers: configure `extra_nodes` group with hostnames
- Add `nvidia_gpu_node: true` to GPU nodes
- Add `workstation: true` to workstation nodes if applicable
- For multi-homed nodes (multiple NICs on different subnets): set `node_ip`
  to the IP on the cluster subnet and `flannel_iface` to the matching
  interface name — otherwise K3s and flannel may auto-detect the wrong subnet

### `group_vars/all.yml`
- Set `control_plane`, `cluster_domain`, `domain_email`, `repo_remote`,
  `repo_branch`

### `kubernetes-services/templates/longhorn.yaml`
- If <3 nodes: change `defaultClassReplicaCount` to match node count (1 or 2)

### `kubernetes-services/values.yaml`
- Set `repo_branch` to match `all.yml`
- Configure NFS settings if applicable (only if rkllama/llamacpp selected)
- Set `enable_oauth2_proxy: false` (user enables later)
- Set `enable_cloudflare_tunnel: false` (user enables later)
- Set `enable_supabase: false` unless user wants Open Brain now
- Set `oauth2_emails` list

## Phase 3: SSH key setup

Check if `pub_keys/ansible_rsa.pub` exists. If not:

```bash
# Advise the user to run this on their HOST machine (outside devcontainer):
ssh-keygen -t rsa -b 4096 -C "ansible master key" -f $HOME/.ssh/ansible_rsa
cp $HOME/.ssh/ansible_rsa.pub <repo-path>/pub_keys/ansible_rsa.pub
```

For Turing Pi users, remind them to copy the key to BMC(s) per the tutorial.
For generic servers, remind them to run `ansible-playbook pb_add_nodes.yml`.

## Phase 4: Run the playbook

Confirm with the user before running. `GENERATE_SECRETS=true` handles all
secret generation, sealing, admin password, and git commit/push automatically.

If the user wants a specific admin password, set `ADMIN_PASSWORD` in the
environment. Otherwise one is generated randomly.

**Turing Pi (first time):**
```bash
GENERATE_SECRETS=true \
SSH_AUTH_SOCK="/tmp/ssh-agent.sock" \
ansible-playbook pb_all.yml -e do_flash=true
```

**Generic servers:**
```bash
ansible-playbook pb_all.yml --tags tools

GENERATE_SECRETS=true \
SSH_AUTH_SOCK="/tmp/ssh-agent.sock" \
ansible-playbook pb_all.yml --tags known_hosts,servers,k3s,cluster
```

The playbook automatically:
1. Installs K3s on all nodes
2. Deploys ArgoCD with full config
3. Waits for the sealed-secrets controller
4. Generates all secrets fresh (admin password, Supabase JWTs, Dex
   client secrets, cookie secrets, etc.)
5. Seals them with `kubeseal` and commits/pushes the sealed files
6. Sets the admin password and prints it to the output

The admin password is saved to `/tmp/cluster-secrets/admin-password.txt`.

Wait for completion and verify:
```bash
kubectl get nodes
kubectl get applications -n argo-cd
```

## Phase 5: Post-deploy setup

### Verify cluster health

```bash
just status
```

Run repeatedly until all nodes are Ready and all ArgoCD apps are
Synced/Healthy.

## Phase 6: Write credentials file

Write all generated credentials to `/tmp/cluster-credentials.txt` with clear
labels. Include:

- Admin password (from `/tmp/cluster-secrets/admin-password.txt`)

Warn the user to save this file somewhere secure and that `/tmp` is ephemeral.

## Phase 7: Summary and next steps

Print a summary of what was configured and deployed, then direct the user to
the relevant documentation for remaining manual steps:

- **All users**: `docs/how-to/accessing-services` for port-forward commands
- **Cloudflare tunnel**: `docs/how-to/cloudflare-tunnel` (4-part guide)
- **OAuth setup**: `docs/how-to/oauth-setup` (GitHub OAuth app)
- **Open Brain**: `docs/how-to/open-brain` (Cloudflare hostnames + Claude.ai MCP connector)
- **LLM models**: `docs/how-to/rkllama-models` or `docs/how-to/llamacpp-models`
