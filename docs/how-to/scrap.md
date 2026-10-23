# Deploy scrap

[scrap](https://github.com/gilesknap/scrap) is a personal knowledge store: a
web app (installable as a PWA) plus an MCP endpoint at `/mcp` for AI coding
tools. The application and its Helm chart live in the scrap repository. This
repository provides the cluster wiring:

- An ArgoCD Application (`kubernetes-services/templates/scrap.yaml`) that
  deploys the chart from a git tag, with a NetworkPolicy, a local-disk data
  volume, a nightly backup CronJob and Claude ingest (enabled in this deployment).
- An ingress for `scrap.<domain>` gated by oauth2-proxy, plus a second
  `/mcp`-only ingress without oauth2-proxy
  (`kubernetes-services/additions/scrap/`), disabled by default (see below).
- A `local_storage.scrap` volume and a `k8s_data_dirs` entry for the data
  directory.

scrap has no login of its own, so access control is layered in front of it.

## Authentication layers

| Path | Layer 1 | Layer 2 |
|------|---------|---------|
| Web UI / PWA | Cloudflare Access (email one-time PIN) | oauth2-proxy GitHub login, limited to `admin_emails` |
| `/mcp` | Cloudflare Access service token (`CF-Access-Client-Id` / `CF-Access-Client-Secret` headers) | scrap bearer token |

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

1. Make sure the data directory exists on the pinned node:
   `ansible-playbook pb_all.yml --tags servers` runs the `k8s_data_dirs`
   role, which creates `/home/k8s-data/scrap`.
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

## Cloudflare configuration

In the Cloudflare dashboard, following {doc}`cloudflare-web-tunnel`:

1. Add a public hostname `scrap.<domain>` on the tunnel pointing at
   ingress-nginx.
2. Make sure an Access application covers the whole host with an email
   one-time-PIN policy (a wildcard application is enough). Use a long session
   duration so the PWA is not constantly challenged.
3. Add a more specific Access application for `scrap.<domain>/mcp` with a
   Service Auth policy and a service token. Store the token safely.
4. Confirm the more specific application wins for `/mcp`.

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
```

- The PVC is bound to the local volume on the pinned node.
- A browser with no cookies is sent to Cloudflare, then GitHub.
- `/mcp` without the Cloudflare headers is refused at the edge; with them but
  without the scrap token it returns 401; with both it works.
- A capture from the phone appears, and the nightly backup CronJob completes.
