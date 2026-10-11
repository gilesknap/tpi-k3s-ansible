# Run the Minecraft Dashboard

The Minecraft dashboard is an admin-only web UI at `minecraft.<domain>` that
launches Minecraft Java servers from world backups, monitors them, stops and
starts them while keeping their data, and saves their state back as
snapshots and backups. Players connect with an ordinary Minecraft client to
`mc.<domain>:<port>`.

The dashboard application and its Helm chart live in a separate repository,
[gilesknap/k3s-minecraft](https://github.com/gilesknap/k3s-minecraft), and are
published as the OCI chart `ghcr.io/gilesknap/charts/minecraft-dashboard`.
This repository only provides the cluster wiring:

- An ArgoCD Application (`kubernetes-services/templates/minecraft.yaml`),
  toggled by `enable_minecraft` and configured from the `minecraft` block in
  `kubernetes-services/values.yaml`.
- An ingress for `minecraft.<domain>`, gated by oauth2-proxy (admin emails
  only, the same as Headlamp).
- An optional DDNS CronJob (`kubernetes-services/additions/minecraft/`) that
  keeps the game hostname pointed at your WAN IP.

## How it fits together

| Piece | Where | Notes |
|-------|-------|-------|
| Dashboard Deployment, Service, ServiceAccount, namespace-scoped Role | OCI chart, namespace `minecraft` | The dashboard runs `helm` against the itzg Minecraft chart inside its own namespace only |
| Archive of precious world backups | NAS `<archive_path>` (default `/bigdisk/minecraft-archive`) | Read-only twice over: `a-w` on the NAS **and** a read-only mount |
| Store: promoted backups, rolling snapshots, dashboard state | NAS `<nfs.cluster_share_path>/minecraft` | Written by the dashboard as uid/gid 1000 |
| Live world data | One dynamic `nfs-rwx` PVC per world | Created by the dashboard; deleted with the world (after a snapshot) |
| Game ports | NodePorts `30565`–`30584` on the pinned node | 20 slots; one per world for the world's lifetime |
| Game hostname `mc.<domain>` | Cloudflare **DNS-only** A record | Kept current by the DDNS CronJob |
| Dashboard hostname `minecraft.<domain>` | Cloudflare tunnel route | Cloudflare Access + oauth2-proxy |

:::{important}
The game hostname is **not** a tunnel route. Cloudflare's tunnel and proxy only
carry HTTP(S); Minecraft speaks its own TCP protocol, so players reach the
cluster through a router port-forward and a grey-cloud DNS record that points
straight at your WAN IP.
:::

## Prerequisites

- A NAS reachable over NFS, already set up as in {doc}`nas-setup`.
- The `nfs-csi` storage class (`nfs_csi.storage_class`, default `nfs-rwx`)
  working — world data is provisioned from it.
- oauth2-proxy working ({doc}`oauth-setup`) and the Cloudflare web tunnel set
  up ({doc}`cloudflare-web-tunnel`).
- A router you can configure to forward a TCP port range to one node.
- The dashboard chart version you pin in `minecraft.chart_version` must be
  published. Check before enabling:

  ```bash
  helm pull oci://ghcr.io/gilesknap/charts/minecraft-dashboard --version 0.1.0
  ```

## Step 1: Create the NAS directories

Follow {ref}`minecraft-nas-directories` in {doc}`nas-setup` to create the read-only archive directory and the writable store tree.

## Step 2: Ingest the world archive

World backups downloaded from Google Drive arrive as a set of split wrapper
zips (`minecraft-k8s-backup-*-NNN.zip`), each holding one inner zip per world.
The `scripts/ingest-archive.sh` script in the k3s-minecraft repository
extracts the inner zips **flat, keeping their original filenames**, checks
each one (`unzip -t` plus a `world/level.dat` entry), and is idempotent — re-run
it later to add more files.

Run it on the NAS, or on any Linux host with the NAS share mounted read-write:

```bash
git clone https://github.com/gilesknap/k3s-minecraft.git
cd k3s-minecraft

# <dest> first, then every downloaded wrapper zip
scripts/ingest-archive.sh /share/CACHEDEV1_DATA/bigdisk/minecraft-archive \
  ~/Downloads/minecraft-k8s-backup-*.zip
```

Ingest **every** version of every world — older copies can hold builds that
were lost from newer ones. Never rename the files; the dashboard parses the
world name and date from them.

Then lock the archive so nothing can modify it, on the NAS:

```bash
chmod -R a-w /share/CACHEDEV1_DATA/bigdisk/minecraft-archive
```

To add more files later, temporarily restore write access to the directory
(`chmod u+w`), re-run the ingest script, and lock it again with
`chmod -R a-w`.

## Step 3: Forward the game ports on your router

All worlds are pinned to one node (`minecraft.worlds.node`, for example
`nuc2`), and their Services use `externalTrafficPolicy: Local` so the servers
see real player IPs. Forward the whole range to that node:

| Protocol | External ports | Internal host | Internal ports |
|----------|----------------|---------------|----------------|
| TCP | `30565`–`30584` | LAN IP of the pinned node (e.g. `192.168.1.92`) | `30565`–`30584` |

Give the pinned node a static DHCP lease so the forward keeps working. If you
change `minecraft.worlds.port_min`/`port_max`, change the forward to match.

## Step 4: Create the DDNS token and seal it

The DDNS CronJob runs [favonia/cloudflare-ddns](https://github.com/favonia/cloudflare-ddns)
every five minutes. It detects your WAN IP and creates or updates the
`mc.<domain>` A record as **DNS-only** (`PROXIED=false`), with no AAAA record.
It needs its own Cloudflare API token, scoped to editing DNS in one zone.

### Create the token

In the Cloudflare dashboard ([dash.cloudflare.com](https://dash.cloudflare.com/)):

1. Go to **My Profile → API Tokens → Create Token**.
2. Use the **Edit zone DNS** template.
3. Set **Permissions** to `Zone` / `DNS` / `Edit` (the template default).
4. Set **Zone Resources** to `Include` / `Specific zone` / your domain.
5. Optionally restrict **Client IP Address Filtering** to your WAN IP range.
6. **Continue to summary → Create Token**, and copy the token.

:::{note}
You could reuse the cert-manager DNS-01 token's value, but a dedicated token
can be revoked on its own and shows up separately in the Cloudflare audit log.
:::

### Check the existing DNS record

In **DNS → Records** for your zone, look for an existing `mc` record.
cloudflare-ddns leaves the proxy status of an existing record unchanged, so
if one exists make sure it is an `A` record with the **DNS only** (grey cloud)
proxy status — or delete it and let the CronJob create it. It must not be a
tunnel CNAME.

### Seal the token

Seal the token into the `minecraft` namespace as the `cloudflare-ddns-token`
Secret (key `api-token`). The file name must end in `-secret.yaml`
(singular) — the `.gitleaks.toml` allowlist only covers that pattern. See
{doc}`manage-sealed-secrets` for background.

```bash
# Prompt for the token (not echoed, not stored in shell history)
printf 'Cloudflare DDNS token: ' && read -rs CF_DDNS_TOKEN && echo

printf '%s' "$CF_DDNS_TOKEN" | \
  kubectl create secret generic cloudflare-ddns-token \
    --namespace minecraft \
    --from-file=api-token=/dev/stdin \
    --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets \
    --controller-namespace kube-system -o yaml > \
    kubernetes-services/additions/minecraft/templates/cloudflare-ddns-secret.yaml

unset CF_DDNS_TOKEN
```

The `minecraft` namespace does not need to exist yet — a SealedSecret is bound
to the name and namespace it was sealed for, not to a live object.

:::{tip}
For cluster rebuilds, export the token as `MINECRAFT_DDNS_API_TOKEN` alongside
the other external credentials. `scripts/export-external-creds` captures it
from a running cluster, and `just generate-and-seal-all` re-seals it when it is
set (and skips it when it is not).
:::

## Step 5: Add the dashboard tunnel route

Tunnel routes are managed in the Cloudflare dashboard, not in this repository.
Add a route for the dashboard exactly as for the other web services in
{doc}`cloudflare-web-tunnel` (Part 2):

| Subdomain | Domain | URL |
|-----------|--------|-----|
| `minecraft` | `example.com` | `http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local` |

Delete any existing `minecraft` A record first so Cloudflare can create the
tunnel CNAME. A wildcard Cloudflare Access application already covers the new
hostname; no Access change is needed. Do **not** add a route for `mc`.

## Step 6: Enable the dashboard

Edit `kubernetes-services/values.yaml`:

```yaml
enable_minecraft: true
minecraft:
  chart_version: "0.1.0"          # must be published (see Prerequisites)
  archive_path: /bigdisk/minecraft-archive
  store_subdir: minecraft         # under nfs.cluster_share_path
  dns_name: mc                    # players use mc.<cluster_domain>
  worlds:
    node: nuc2                    # the node your router forwards to
    port_min: 30565
    port_max: 30584
  ddns:
    enabled: true                 # only once cloudflare-ddns-secret.yaml exists
```

The chart also takes its NFS server from `nfs.server` and the world storage
class from `nfs_csi.storage_class`.

The ArgoCD AppProject must allow the chart registry. `argo-cd/argo-project.yaml`
lists `ghcr.io/gilesknap/charts` (bare, with no `oci://` prefix); apply the
project change with:

```bash
ansible-playbook pb_all.yml --tags cluster
```

Commit and push. ArgoCD creates the `minecraft` Application and namespace.

## Step 7: First test with a disposable world

Prove the whole path with a world you do not care about before touching a
precious one.

1. **ArgoCD** — the `minecraft` Application is Synced and Healthy:

   ```bash
   kubectl get application minecraft -n argo-cd
   kubectl get pods,pvc -n minecraft
   ```

2. **Archive is read-only** — writes through the archive mount must fail:

   ```bash
   kubectl exec -n minecraft deploy/minecraft-dashboard -- \
     touch /archive/should-fail    # expect "Read-only file system"
   ```

3. **DDNS** — trigger a run and check the record:

   ```bash
   kubectl create job -n minecraft ddns-test --from=cronjob/cloudflare-ddns
   kubectl logs -n minecraft job/ddns-test
   dig +short mc.example.com     # should print your WAN IP
   kubectl delete job -n minecraft ddns-test
   ```

   In the Cloudflare dashboard the `mc` record shows **DNS only**.

4. **Dashboard login** — open `https://minecraft.example.com`. You should pass
   Cloudflare Access, then the GitHub login via oauth2-proxy. A non-admin
   GitHub account must be refused.
5. **Launch** a disposable, non-precious world from the archive list. Watch it
   go seeding → starting → running, and note its port.
6. **Connect** from a real Minecraft Java client to `mc.example.com:<port>`,
   from outside your LAN (for example over a phone hotspot) to prove the
   router forward and DNS. The player must be on the world's whitelist.
7. **Stop** the world, then **start** it again — the world data survives.
8. **Snapshot** it, change something in game, then **restore** the snapshot.
9. **Delete** the world. A final snapshot is taken first and the port is freed.

Only after all of that works, try a modded (Forge) world, and only then a
precious one.

## Troubleshooting

### The `minecraft` app shows `InvalidSpecError` or a 403/404

Either the AppProject does not list `ghcr.io/gilesknap/charts` (run
`--tags cluster`), the repoURL has an `oci://` prefix, or the chart version
is not published. See the ArgoCD notes in `.claude/skills/argocd/SKILL.md`.

### DDNS job fails

```bash
kubectl get jobs -n minecraft
kubectl logs -n minecraft job/<job-name>
```

`CreateContainerConfigError` means the `cloudflare-ddns-token` Secret does not
exist — the SealedSecret is missing or was sealed for another cluster or
namespace. An authentication error from Cloudflare means the token is wrong
or not scoped to the zone.

### Players cannot connect

- Check `dig +short mc.<domain>` returns your current WAN IP.
- Check the router forward targets the pinned node's current LAN IP.
- From the LAN, try `<node-ip>:<port>` directly to separate a cluster
  problem from a router/DNS problem.
- Some routers do not support NAT loopback; LAN players may need the node IP
  instead of `mc.<domain>`.

## Removing the dashboard

First **delete every world from the dashboard** — each delete takes a final
snapshot. Worlds are Helm releases and PVCs created by the dashboard at
runtime, not by ArgoCD, so ArgoCD will not clean them up, and deleting a
world PVC by hand loses its data (`nfs-rwx` uses `reclaimPolicy: Delete`).

Then set `enable_minecraft: false` and push. ArgoCD prunes the dashboard,
its ingress and the DDNS CronJob. The NAS archive and store directories are
static NFS volumes and are never deleted by the cluster; remove the `mc` DNS
record, the `minecraft` tunnel route and the router forward by hand.
