# Deploy scrap

[scrap](https://github.com/gilesknap/scrap) is a personal knowledge store: a
web app (installable as a PWA) plus an MCP endpoint at `/mcp` for AI coding
tools. The application and its Helm chart live in the scrap repository. This
repository provides the cluster wiring:

- An ArgoCD Application (`kubernetes-services/templates/scrap.yaml`) that
  deploys the published OCI chart, with a NetworkPolicy, the chart's
  Litestream mode on NFS volumes (so scrap runs on any node), a nightly backup
  CronJob and Claude ingest (enabled in this deployment).
- An ingress for `scrap.<domain>` gated by oauth2-proxy, plus a second
  `/mcp`-only ingress without oauth2-proxy
  (`kubernetes-services/additions/scrap/`), off by default in the chart, on in
  this deployment (see below).
- Static NFS volumes for the data and the backups, and a nightly copy of the
  newest backup off the NAS (`kubernetes-services/additions/scrap/`); see
  [Data, backups and failover](#data-backups-and-failover).
- Public pages: the chart's `public` section serves the pages marked Public
  as a static site at `pages.<domain>`, from its own `scrap-public` namespace
  (see [Public pages](#public-pages)).

scrap has no login of its own, so access control is layered in front of it.

## Authentication layers

| Path | Layer 1 | Layer 2 |
|------|---------|---------|
| Web UI / PWA | Cloudflare Access (email one-time PIN) | oauth2-proxy GitHub login, limited to `admin_emails` |
| `/mcp` | Cloudflare Access service token (`CF-Access-Client-Id` / `CF-Access-Client-Secret` headers) | scrap bearer token |
| `pages.<domain>` | None: a Cloudflare Access **Bypass** application, as the site is public | None: static files only, nothing can reach scrap |

The `/mcp` path cannot use oauth2-proxy because MCP clients cannot complete a
browser login. It has its own Ingress, and nginx routes to the most specific
path, so `/mcp` skips the oauth2 annotations of the main ingress.

:::{note}
Hosted MCP connectors that run from a vendor's cloud (for example a chat
app's custom connector) cannot send Cloudflare service-token headers, so they
cannot reach `/mcp` through this design.
:::

:::{warning}
The `/mcp` Ingress is gated by `mcp_ingress_enabled` in
`kubernetes-services/templates/scrap.yaml`. Keep it `true` only while the scrap
chart `targetRevision` is a release with `SCRAP_MCP_TOKEN` bearer auth
(0.2.0 or later) and `mcp.tokenSecret` is set. Until then Cloudflare would be
the only protection on `/mcp`, and ingress-nginx is reachable directly (LAN or
split DNS) bypassing Cloudflare.
:::

The NetworkPolicy admits only the `ingress-nginx` namespace, so nothing else
in the cluster can reach the pod or forge identity headers.

## Deploy

1. Create scrap's directories on the NAS ({doc}`nas-setup`), and the
   directory for the off-NAS backup copy:
   `ansible-playbook pb_all.yml --tags servers` runs the `k8s_data_dirs`
   role, which creates it (`local_storage.scrap_backup_copy`).
2. Seal the Claude API key into the `scrap-secrets` SealedSecret (ingest is
   enabled, so this is required). Follow
   `kubernetes-services/additions/scrap/README.md` and
   {doc}`manage-sealed-secrets`. The file is
   `kubernetes-services/additions/scrap/templates/scrap-secret.yaml`.
3. Commit, then let ArgoCD sync. Do this only after step 2: until the
   SealedSecret exists the pod sits in `CreateContainerConfigError` because
   it references the missing `scrap-secrets` Secret.
4. For `/mcp`, seal `SCRAP_MCP_TOKEN` into the same Secret, point
   `mcp.tokenSecret` at it and set `mcp_ingress_enabled: true`. Use a scrap
   release of 0.2.0 or later.

## Data, backups and failover

scrap runs in its chart's Litestream mode (ADR 0013, and scrap's own ADR 46),
with no node pinning:

| What | Where |
|------|-------|
| The database | An emptyDir on the pod's node, at `/db/scrap.db` |
| Its replica, about a second behind | `/data/litestream` on `scrap-data-nfs` (`<cluster share>/scrap-data`) |
| Files and the preview cache | `/data` on `scrap-data-nfs` |
| Backups: daily (keep 7) and monthly (keep 12) | `scrap-backups-nfs` (`<cluster share>/backups/scrap`) |
| The newest backup, copied nightly at 05:00 (keep 3) | The `local_storage.scrap_backup_copy` PV, off the NAS |

Each new pod's `db-init` init container restores the database from the
replica. It fails closed, rather than starting empty, when the volume looks
wrong. gc and the Claude passes (related pages, topics) run on their usual
schedules in the pod's `jobs` container, not as CronJobs: see their runs with
`kubectl -n scrap logs deploy/scrap -c jobs`.

- **Node death:** fence the node ({ref}`fence-a-dead-node`). scrap restarts
  on another node in about 1–2 minutes and loses about a second of writes.
- **Planned moves** (drain, reboot) lose nothing: Litestream does a last sync
  after scrap stops.
- **NAS down:** files cannot be read and replication stalls. After 20 minutes
  the pod leaves its Service, so scrap stops taking writes it cannot protect.
  It recovers by itself when the NAS returns.

Restores: {doc}`backup-restore`.

### Moving an existing install off a local volume

An install that started on a `local-nvme` PV (`local_storage.scrap`) moves in
one Argo CD sync, with `legacy.migrate: true` in `templates/scrap.yaml`
(`false` in this repository, whose own move is done):

1. The NFS PVs and PVCs (sync wave -2).
2. The Job `scrap-migrate-to-nfs` (wave -1), on the old volume's node:
   - it fails unless it can read both the old and the NFS data volume;
   - it does nothing if the NFS data volume already holds a database or a
     replica, or if the old volume holds no database;
   - it copies the complete runs from the old backups claim;
   - it runs `scrap backup` of the live database;
   - it runs `scrap restore` into the NFS data volume.
3. The chart (wave 0). The new pod's `db-init` brings the restored database
   across to its emptyDir.

If the Job fails, the sync stops there and the old pod keeps serving. To
retry, rename the Job in git. Don't capture during the sync: writes made
between the Job's backup and the old pod stopping (about a minute) are not
moved. Don't sync between 03:30 and 05:00 either, when the old pod's gc and
the new one's could overlap on their lock.

Afterwards, the old claim and its PV stay as a frozen copy of the data:
unmounted, `Retain`, at `/home/k8s-data/scrap` on the old node.

#### Check the cut-over

Once the new pod serves, compare the frozen copy with the live database:

```bash
just scrap-cutover-check          # or: scripts/scrap-cutover-check nuc2
```

It reads both sides only: the old database over SSH (as `ansible`, with
`sudo`) opened `immutable=1`, the live one read-only through `kubectl exec`
into the scrap pod. It prints `max(rowid) FROM page_rev`,
`count(*) FROM capture` and `max(updated_at) FROM page` for each, then lists
every revision, capture and page that is newer in the old copy. Exit status 0
means nothing was lost. Rows it lists were written in the cut-over window:
re-enter them in scrap by hand.

#### Fix forward

Once scrap has taken its first write after the cut-over, **fix forward;
revert only before the first write after cut-over.** A revert of the PR goes
back to the frozen copy and silently drops everything written since. Before
that first write, reverting is safe: the old volume holds the same data.

#### Retire the Job straight away

Until the Job is retired, a rebuild depends on the old node: the Job is pinned
there by its local PV, and the sync cannot pass wave -1 without it. As soon as
the check passes, set `legacy.migrate: false` in `templates/scrap.yaml` and
let Argo CD sync. The old dynamic backups claim, `scrap-backups`, is rendered
only so that the Job can mount it: drop `legacy.backups` from
`templates/scrap.yaml` at the same time. Its `Prune=false` keeps the claim in
the cluster, so delete it by hand afterwards. Deleting it deletes its NAS
directory (it was provisioned by the `nfs-rwx` class, then the default: reclaim
policy `Delete`, `onDelete: delete`), so do that only once every run you want
is confirmed in `backups/scrap`. The Job copies only complete runs named by
timestamp: copy any run you renamed by hand (such as a `-curated` one) yourself,
and note that the daily gc on the new claim may already have pruned older runs.

#### New installs

A new install starts on NFS and has nothing to move. Drop the `scrap` entry
from `local_storage` in `kubernetes-services/values.yaml` (and from
`k8s_data_dirs` in `group_vars/all.yml`), so neither the old claim nor the
Job is rendered. If it is kept, the Job finds no database on the old volume,
logs that, and exits successfully.

## Cloudflare configuration

With Cloudflare managed as code ({doc}`cloudflare-as-code`), these are the
`scrap` and `pages` entries in `cloudflare/locals.tf` and the apps in
`cloudflare/access.tf` (including the `/mcp` service-token policy); apply with
`just cf-apply`. Otherwise, in the Cloudflare dashboard, following
{doc}`cloudflare-web-tunnel`:

1. Add a public hostname `scrap.<domain>` on the tunnel pointing at
   ingress-nginx.
2. Make sure an Access application covers the whole host with an email
   one-time-PIN policy (a wildcard application is enough). Use a long session
   duration so the PWA is not constantly challenged.
3. Add a more specific Access application for `scrap.<domain>/mcp` with a
   Service Auth policy and a service token. Store the token safely.
4. Confirm the more specific application wins for `/mcp`.

## Public pages

scrap can publish the pages you mark Public to a static site at
`https://pages.<domain>`, open to anyone. The scrap chart's `public` section
(in `kubernetes-services/templates/scrap.yaml`) runs it in a namespace of its
own, `scrap-public`: one pod with nginx, which serves the site, and an upload
receiver that scrap pushes each public page to. Nothing on the public side can
reach scrap. See the scrap
[deployment guide](https://gilesknap.github.io/scrap/main/how-to/deploy-kubernetes.html#public-pages)
for the design.

This repository provides:

- the `scrap-public` namespace (`additions/scrap/templates/public-namespace.yaml`),
  labelled Pod Security `restricted`. The chart's `public.createNamespace` is
  left `false`, and Argo CD's `CreateNamespace=true` creates only the
  Application's own namespace (`scrap`), so the namespace is a manifest here;
- the upload token, a SealedSecret `scrap-publish` (key `token`) sealed
  **twice**, once for each namespace, because a pod reads only its own
  namespace's Secrets: `scrap-publish-secret.yaml` (`scrap`) and
  `scrap-public-publish-secret.yaml` (`scrap-public`). Both must hold the same
  token; `kubernetes-services/additions/scrap/README.md` has the command that
  seals a new one into both;
- an Ingress for `pages.<domain>` (the chart's `public.ingress`) on the
  `nginx` class with the wildcard certificate, **without** the oauth2-proxy
  annotations. Only nginx is on it; the receiver never is;
- `public.networkPolicy.webFrom`, which admits only the `ingress-nginx`
  namespace to nginx. The chart's NetworkPolicy admits only scrap's pods to
  the receiver, and denies all egress from the namespace.

The image is `ghcr.io/gilesknap/scrap-public`; its package must be public on
GitHub (or the cluster given a pull secret), otherwise the pod cannot pull it.

The site is held in an `emptyDir`, so it starts empty when the pod moves;
scrap checks the receiver's manifest at start and every 10 minutes and pushes
what is missing.

:::{tip}
A cluster rebuild re-seals scrap's secrets. `scripts/export-external-creds`
exports `SCRAP_ANTHROPIC_API_KEY`, `SCRAP_MCP_TOKEN` and
`SCRAP_PUBLISH_TOKEN` from the running cluster, and
`just generate-and-seal-all` seals them into `scrap-secrets` and into
`scrap-publish` in both namespaces. The MCP token is kept, so MCP clients
keep working; set `SCRAP_ROTATE_MCP_TOKEN=true` to replace it, then update
every client. Without `SCRAP_ANTHROPIC_API_KEY`, scrap's secrets are
skipped.
:::

### Cloudflare for the public site

The wildcard Access application covers every subdomain, so without more
configuration readers of `pages.<domain>` meet a login page. With Cloudflare
managed as code ({doc}`cloudflare-as-code`), the `pages` entry in
`cloudflare/locals.tf` (`access_bypass = true`) and its bypass app in
`cloudflare/access.tf` already handle this; apply with `just cf-apply`.
Otherwise, in the Cloudflare dashboard:

1. Add a public hostname `pages.<domain>` on the tunnel pointing at
   ingress-nginx, as for `scrap.<domain>` ({doc}`cloudflare-web-tunnel`).
2. Add an Access application for `pages.<domain>` with a policy whose Action
   is **Bypass** and Include **Everyone**, as in
   [Bypass application for API endpoints](cloudflare-web-tunnel.md#bypass-application-for-api-endpoints).
   The more specific application takes precedence over the wildcard.

## Notes on the unauthenticated path

- Kubernetes probes talk to the pod directly, so no health endpoint needs to
  be exposed through ingress.
- oauth2-proxy sets a cookie on `.<domain>` shared by all services. Its
  default lifetime is 168 hours with no refresh, and the cookie is `SameSite=Lax`.
  After it expires, background `fetch` calls from the PWA (such as an offline
  queue replay) get a redirect to the login page instead of a response. Open
  the app in the browser to log in again, then the queue replays.
- A cross-site top-level POST (for example an Android share target started
  from another app) does not carry a `Lax` cookie, so the first share after
  expiry may land on the login page. Verify this on your device.
- nginx does not strip client-supplied identity headers on the `/mcp` path.
  Do not rely on any identity header there until scrap can be told which
  header to trust.

## Verify

```bash
kubectl -n scrap get pods,pvc,networkpolicy
kubectl -n scrap logs deploy/scrap -c db-init
```

- `scrap-data-nfs` and `scrap-backups-nfs` are bound to their NFS PVs.
- `db-init` says it restored the replica, or on the first start, brought
  `/data/scrap.db` across. It never says it made a new database for an
  install that has data.
- A browser with no cookies is sent to Cloudflare, then GitHub.
- `/mcp` without the Cloudflare headers is refused at the edge; with them but
  without the scrap token it returns 401; with both it works.
- A capture from the phone appears, and the nightly backup CronJob completes.

For public pages:

```bash
kubectl -n scrap-public get pods,ingress,networkpolicy,secret
```

From outside your private network:

- `https://pages.<domain>/` returns 200, with no Cloudflare Access redirect.
- `https://pages.<domain>/v1/manifest` returns 404: the receiver is not on
  the Ingress.
- In scrap, `/api/health` shows `enabled: true` in its `publish` block.
