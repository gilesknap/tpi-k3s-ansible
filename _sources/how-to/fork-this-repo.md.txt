# Fork This Repo

This repo was designed to be forkable: edit a small number of well-known
files, push to your own fork, and the playbook + ArgoCD will deploy a
clone of the cluster against your hardware. This guide walks through
every file you need to touch.

## The two-file model

The bulk of cluster-specific configuration lives in just two files:

| File | Owns |
|---|---|
| `group_vars/all.yml` | Ansible-side: cluster domain, admin emails, repo URL/branch, host data directories. |
| `kubernetes-services/values.yaml` | ArgoCD/Helm-side: NFS server, local PV layout, OAuth, supabase release name, image repositories. |

A third file, `inventory/hosts.yml`, owns the node inventory itself —
hostnames, IPs, BMC addresses. Fork this directly to match your
hardware (it is **not** templated through values.yaml on purpose).

## Step-by-step fork

### 1. Fork on GitHub and clone

Fork `gilesknap/tpi-k3s-ansible` on GitHub, then clone your fork.

### 2. Point the cluster at your fork

In `group_vars/all.yml`:

```yaml
repo_remote: https://github.com/<your-user>/<your-fork>.git
repo_branch: main
cluster_domain: <your-domain>
domain_email: <your-email>  # for letsencrypt
admin_emails:
  - <your-email>
```

In `kubernetes-services/values.yaml`, mirror the admin emails:

```yaml
admin_emails:
  - <your-email>
```

### 3. Edit the inventory

`inventory/hosts.yml` lists every node and BMC. Replace hostnames,
IPs, MAC addresses, and BMC URLs with your own. The host names you
choose here (`node01`, `node02`, `nuc2`, etc.) are referenced in the
storage maps below — keep them consistent.

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

- `inventory/hosts.yml` — fork-specific inventory, edit directly.
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

Both should pass cleanly. Then proceed with {doc}`bootstrap-cluster`.
