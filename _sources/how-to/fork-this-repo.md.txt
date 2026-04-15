# Fork This Repo

This repo was designed to be forkable: edit a small number of well-known
files, push to your own fork, and the playbook + ArgoCD will deploy a
clone of the cluster against your hardware. This guide walks through
every file you need to touch.

:::{tip}
This is a **reference** to every fork-edit knob — read it alongside
whichever tutorial you picked
({doc}`/tutorials/getting-started-tpi`,
{doc}`/tutorials/getting-started-generic`, or
{doc}`/tutorials/ai-guided-setup`). The tutorials walk the happy-path
minimum; this guide covers the full set of options (storage mapping,
per-node flags, service toggles, rkllama pinning, re-sealing).
:::

## The three files you must edit

Cluster-specific configuration lives in three files. Expect to edit
all three before your first deploy:

| File | Owns |
|---|---|
| `hosts.yml` | Your hardware: hostnames, IPs, BMC addresses, per-node flags (slot, type, root device, GPU, workstation). |
| `group_vars/all.yml` | Ansible-side: cluster domain, admin emails, repo URL/branch, host data directories. |
| `kubernetes-services/values.yaml` | ArgoCD/Helm-side: NFS server, local PV layout, OAuth, supabase release name, image repositories. |

`hosts.yml` is deliberately **not** templated through the other two —
every fork's hardware is different, and the flash/known_hosts roles
rely on group-name conventions (`<bmc>_nodes`) that don't survive
templating cleanly. Edit it directly. The node names you choose there
are referenced from the other two files, so pick them first.

See {doc}`/reference/inventory` for the full list of per-node
variables and group naming rules.

## Step-by-step fork

### 1. Fork on GitHub and clone

Follow Step 1 of {doc}`/tutorials/getting-started-tpi` or
{doc}`/tutorials/getting-started-generic` to fork, clone, and generate
the Ansible SSH keypair, then return here for the full configuration
walkthrough.

### 2. Edit the inventory

`hosts.yml` lists every node and BMC. Replace hostnames,
IPs, MAC addresses, and BMC URLs with your own.

Per-node variables that matter:

- `slot_num` / `type` — for Turing Pi nodes, the physical slot and
  compute module type (`pi4` / `rk1`).
- `root_dev` — set to migrate the OS to NVMe; omit for servers
  already on their target disk.
- `nvidia_gpu_node: true` — enables the NVIDIA driver and container
  toolkit on that node. Required for llama.cpp CUDA.
- `workstation: true` — applies a `NoSchedule` taint. Useful for
  machines that reboot unexpectedly (only tolerating workloads land
  there).
- `node_ip` / `flannel_iface` — required on multi-homed nodes.

Turing Pi node groups **must** be named `<bmc_hostname>_nodes` — the
flash role uses this convention to discover which nodes belong to
which BMC. Full reference: {doc}`/reference/inventory`.

The host names you choose here (`node01`, `node02`, `nuc2`, etc.) are
referenced from `group_vars/all.yml` and
`kubernetes-services/values.yaml` — pick them before the next two
steps and keep them consistent across all three files.

### 3. Point the cluster at your fork

In `group_vars/all.yml`:

```yaml
repo_remote: https://github.com/<your-user>/<your-fork>.git
repo_branch: main
cluster_domain: <your-domain>
domain_email: <your-email>  # for letsencrypt
admin_emails:
  - <your-email>
control_plane: <your-control-plane-node>  # must match a host in hosts.yml
```

In `kubernetes-services/values.yaml`, mirror the admin emails:

```yaml
admin_emails:
  - <your-email>
```

### 4. Map storage to your nodes

Two parallel data structures describe where stateful workloads live.
**They must agree.**

- `local_storage` in `kubernetes-services/values.yaml` — drives the
  Kubernetes PV definitions (node affinity, host path, claimRef).
- `k8s_data_dirs` in `group_vars/all.yml` — Ansible loop that creates
  the matching host directories on each node.

For each entry, the `node` and `path` fields **must match** between
the two files. If they drift, the PV's nodeAffinity will point at a
directory that doesn't exist and the PVC will hang Pending.

For a fork retargeting Grafana from `node03` to `nodeX`:

```yaml
# kubernetes-services/values.yaml
local_storage:
  grafana:
    node: nodeX
    path: /var/lib/k8s-data/grafana
    # ... rest unchanged

# group_vars/all.yml
k8s_data_dirs:
  - name: grafana
    node: nodeX
    path: /var/lib/k8s-data/grafana
    # ... rest unchanged
```

The `claim_namespace` and `claim_name` fields in `local_storage` are
determined by upstream chart naming conventions — don't change them
unless you also rename Helm releases.

### 5. NFS share for backups and large models

Backup CronJobs and the rkllama/llamacpp model stores write to an NFS
share on your NAS. In `kubernetes-services/values.yaml`:

```yaml
nfs:
  server: <nas-ip>
  cluster_share_path: /<your-share>/k8s-cluster
rkllama:
  nfs:
    server: <nas-ip>
    path: /<your-share>/k8s-cluster/models
  node: nodeX  # which RK1 hosts the rkllama daemonset
```

Then run the one-time NAS setup runbook in {doc}`nas-setup`.

### 6. Pin rkllama and open-brain-mcp

If you use these services, set:

```yaml
rkllama:
  node: <RK1-with-32GB-RAM>
open_brain_mcp:
  image_repository: ghcr.io/<your-user>/open-brain-mcp
  github_allowed_users: "<your-github-login>"
```

### 7. Re-seal secrets

SealedSecrets are bound to the cluster's controller key, so the
existing committed secrets won't decrypt on your cluster. After your
first cluster bootstrap, follow {doc}`manage-sealed-secrets` to
re-seal every secret with your cluster's key.

### 8. (Optional) Disable services you don't want

Top-level toggles in `kubernetes-services/values.yaml`:

```yaml
enable_oauth2_proxy: false   # disables OAuth gating on Longhorn/Studio/Headlamp
enable_cloudflare_tunnel: false  # if you don't expose services to the internet
enable_supabase: false       # disables the supabase stack and open-brain-mcp
enable_open_brain_mcp: false # standalone disable for open-brain-mcp
```

Whole-service Application templates can also be removed by deleting
the corresponding file in `kubernetes-services/templates/`.

### 9. (Optional) Customise the home page LAN links

The home page (`kubernetes-services/additions/home/templates/manifests.yaml`)
hard-codes a couple of LAN-only service links (router, media server).
These are intentionally not templated — every fork's local network is
different. Edit the HTML directly to match your LAN.

## What's NOT templated (by design)

- `hosts.yml` — hardware topology varies too much between
  forks to template. Group names (`<bmc>_nodes`) are load-bearing
  for the flash role, and per-node flags (`root_dev`,
  `nvidia_gpu_node`, `workstation`) are specific to the physical
  machines. Edit it directly.
- Sealed secrets — bound to the cluster controller key, must be
  re-sealed per cluster.
- Home page LAN service links — too varied per fork to design a
  generic schema; just edit the HTML.

## Verifying your fork

Before the first deploy, sanity-check templating:

```bash
just check
helm template kubernetes-services
```

Both should pass cleanly. Then run the playbook per your tutorial
({doc}`/tutorials/getting-started-tpi` or
{doc}`/tutorials/getting-started-generic`) and verify nodes/apps as
described in its final step. Once the cluster is up, proceed with
{doc}`bootstrap-cluster`.
