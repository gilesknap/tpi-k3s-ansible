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

Neither of these is a choice; tell the user what will happen:

- **Control plane taint**: the cluster role adds the control plane
  `NoSchedule` taint automatically whenever `all_nodes` has more than one
  host. A single-node cluster runs its workloads on the control plane.
- **Cloudflared replicas**: `additions/cloudflared/deployment.yaml` runs a
  fixed 2 replicas with pod anti-affinity, so it needs 2 schedulable nodes.
  A 1-node cluster that enables the tunnel must lower `replicas` in that
  file by hand.

Storage replication: the cluster uses static local hostPath PVs (defined
in `kubernetes-services/values.yaml` under `local_storage`) and NFS, with
no replicated block storage. Each local-PV workload lives on a single
pinned node — warn the user that node loss takes that workload offline
until the node is recovered.

### Hardware-gated features

Only **offer** these features if the cluster has the required hardware.
If the hardware is absent, tell the user the feature is unavailable and why.

| Feature | Requirement | Reason |
|---------|-------------|--------|
| **NFS storage** | Ask if user wants **backups** | NFS backs the daily/weekly backup CronJobs |

### Single-node cluster notes

Single-node clusters work fine — K3s runs as both control plane and worker.
Warn the user about these trade-offs:
- No storage redundancy — static local PVs live on whichever node they
  were pinned to; losing the node loses the workload until recovery
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

7. **NFS server?** — Ask if the user wants any
   backups. If yes: IP and the cluster share
   path on the NAS (e.g. `/bigdisk/k8s-cluster`).
8. **OAuth and Cloudflare credentials now?** (yes/no, default: no — set up
   later). `GENERATE_SECRETS=true` needs all six of `GITHUB_CLIENT_ID`,
   `GITHUB_CLIENT_SECRET`, `OAUTH2_PROXY_CLIENT_ID`,
   `OAUTH2_PROXY_CLIENT_SECRET`, `CLOUDFLARE_API_TOKEN` and
   `CLOUDFLARE_TUNNEL_TOKEN`, and fails if any is missing. If yes, point the
   user at `docs/how-to/oauth-setup` (GitHub OAuth apps) and
   `docs/how-to/cloudflare-as-code` (API and tunnel tokens) and have them
   export the six variables in the shell that runs the playbook.

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
- Set `control_plane`, `cluster_domain`, `domain_email`, `admin_emails`,
  `repo_remote`, `repo_branch`
- Update `k8s_data_dirs` entries so each stateful workload's `node`
  matches a hostname from `hosts.yml`. The `node` and `path` for each
  entry **must match** the corresponding entry in `local_storage` in
  `kubernetes-services/values.yaml` — if they drift, the PV's
  `nodeAffinity` will point at a directory that doesn't exist and the
  PVC will hang Pending.

### `kubernetes-services/values.yaml`
- Set `repo_branch` to match `all.yml`
- Set `admin_emails` — **must be identical to the list in `all.yml`**
  (these are two separate sources of truth by design: Ansible-rendered
  templates read from `all.yml`, ArgoCD-rendered Helm reads from here)
- Update `local_storage` entries so each workload's `node` matches a
  hostname from `hosts.yml` AND the matching `k8s_data_dirs` entry.
  Leave `claim_namespace`/`claim_name` alone unless renaming Helm releases.
- Configure `nfs.server` and `nfs.cluster_share_path` if the user said yes
  to NFS (needed for backups).
- Set `enable_oauth2_proxy: false` (user enables later)
- Set `enable_cloudflare_tunnel: false` (user enables later)

### `kubernetes-services/additions/home/templates/manifests.yaml`
- Contains hard-coded LAN-only service links (router, media server). Not
  templated by design — every fork's local network is different.
  Flag this to the user for a manual edit later; don't block the bootstrap
  on it.

## Phase 3: SSH key setup

Check if `pub_keys/ansible_rsa.pub` exists. If not:

```bash
# Advise the user to run this on their HOST machine (outside devcontainer):
ssh-keygen -t rsa -b 4096 -C "ansible master key" -f $HOME/.ssh/ansible_rsa
cp $HOME/.ssh/ansible_rsa.pub <repo-path>/pub_keys/ansible_rsa.pub
```

For Turing Pi users, remind them to copy the key to BMC(s) per the tutorial.
For generic servers, remind them to (1) add their hosts to the
`extra_nodes` group in `hosts.yml` first, then (2) run
`ansible-playbook pb_add_nodes.yml -e ansible_user=<existing-user> -K`
themselves (`-K` prompts for that user's sudo password; this seeds the
`ansible` account via SSH key + sudoers).

## Phase 4: Run the playbook

Confirm with the user before running. Which form to use depends on
question 8.

### Without OAuth/Cloudflare credentials (default)

Run the playbook without `GENERATE_SECRETS`, then set the shared admin
password (used by Grafana's `admin.existingSecret`):

**Turing Pi (first time):**
```bash
ansible-playbook pb_all.yml -e do_flash=true
just set-admin-password
```

**Generic servers:**
```bash
ansible-playbook pb_all.yml --tags tools
ansible-playbook pb_all.yml --tags known_hosts,servers,k3s,cluster
just set-admin-password
```

The OAuth and Cloudflare secrets are created later, when the user follows
`docs/how-to/oauth-setup` and `docs/how-to/cloudflare-as-code`.

### With all six credentials exported

`GENERATE_SECRETS=true` handles all secret generation, sealing, admin
password, and git commit/push automatically. If the user wants a specific
admin password, set `ADMIN_PASSWORD` in the environment. Otherwise one is
generated randomly.

**Turing Pi (first time):**
```bash
GENERATE_SECRETS=true \
ansible-playbook pb_all.yml -e do_flash=true
```

**Generic servers:**
```bash
ansible-playbook pb_all.yml --tags tools

GENERATE_SECRETS=true \
ansible-playbook pb_all.yml --tags known_hosts,servers,k3s,cluster
```

With `GENERATE_SECRETS=true` the playbook automatically:
1. Installs K3s on all nodes
2. Deploys ArgoCD with full config
3. Waits for the sealed-secrets controller
4. Generates all secrets fresh (admin password, Dex
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
- **Home page LAN links**: edit
  `kubernetes-services/additions/home/templates/manifests.yaml` to match
  the user's local network (router, media server, etc.)
- **Cloudflare tunnel**: `docs/how-to/cloudflare-tunnel` (4-part guide)
- **OAuth setup**: `docs/how-to/oauth-setup` (GitHub OAuth app)
- **NAS setup for backups**: `docs/how-to/nas-setup` (one-time manual runbook)
- **Full fork-edit reference** (anything this command didn't ask about):
  `docs/how-to/fork-this-repo`
