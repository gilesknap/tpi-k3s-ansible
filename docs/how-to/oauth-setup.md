# Set up OAuth authentication

:::{seealso}
{doc}`/explanations/architecture/authentication` explains how the layers
fit together (Cloudflare Access at the edge, then Dex or oauth2-proxy,
then each service's own roles). This page is the runbook for the
credentials behind the two in-cluster layers.
:::

Sign-in inside the cluster goes through GitHub by two paths, each with
its own GitHub OAuth app:

| Path | GitHub OAuth app callback | Used by |
|---|---|---|
| **Dex** (the `argocd-dex-server` Deployment in `argo-cd`), an OIDC provider | `https://argocd.gkcluster.org/api/dex/callback` | ArgoCD, Grafana, argocd-monitor: services that speak OIDC |
| **oauth2-proxy** (two replicas in `oauth2-proxy`), a forward-auth gateway on the ingress | `https://oauth2.gkcluster.org/oauth2/callback` | Headlamp, Alertmanager, the Minecraft dashboard, scrap: admin-only services with no OIDC of their own |

Both apps exist and both paths are live. The steps below are needed on a
rebuild only if the apps have been lost (the rebuild otherwise carries
their credentials over), and to rotate a client secret.

A third GitHub OAuth app, for the Cloudflare Access GitHub login method,
is set up in the Cloudflare dashboard and is not part of this page (see
{doc}`cloudflare-as-code`).

## Part A: Dex

Dex is configured by Ansible, not ArgoCD: the `dex.config` block in
`roles/cluster/tasks/argocd.yml` declares the GitHub connector and three
static clients (`argo-cd`, `argocd-monitor`, `grafana`). Every secret it
names is a key of the `argocd-dex-secret` Secret in `argo-cd`.

### A1: The GitHub OAuth app for Dex

1. Go to [github.com/settings/developers](https://github.com/settings/developers)
   and click **New OAuth App**.
2. Fill in the form:

   | Field | Value |
   |---|---|
   | Application name | `k3s-dex` (any name) |
   | Homepage URL | `https://argocd.gkcluster.org` |
   | Authorization callback URL | `https://argocd.gkcluster.org/api/dex/callback` |

3. Click **Register application**, copy the **Client ID**, then
   **Generate a new client secret** and copy it straight away.

### A2: Seal on a rebuild

On a rebuild every Dex and oauth2-proxy secret is generated and sealed
together, so both OAuth apps (A1 and {ref}`B1 <oauth-b1>`) must exist
first. `just export-external-creds`, run against the old cluster, writes
their credentials to `.env`; the rebuild playbook, run with
`GENERATE_SECRETS=true`, calls `just generate-and-seal-all` with them:

```bash
GITHUB_CLIENT_ID=...            # Dex OAuth app (A1)
GITHUB_CLIENT_SECRET=...
OAUTH2_PROXY_CLIENT_ID=...      # oauth2-proxy OAuth app (B1)
OAUTH2_PROXY_CLIENT_SECRET=...
CLOUDFLARE_API_TOKEN=...        # cert-manager's DNS-01 token
CLOUDFLARE_TUNNEL_TOKEN=...     # the tunnel token
```

(`CLOUDFLARE_API_TOKEN` is described under {ref}`cf-dns01-token`; the
optional variables for scrap, ntfy, the VPS relay and the off-site
backup are listed in `scripts/generate-secrets`.) This seals
`argocd-dex-secret`, `grafana-oauth-secret`, `argocd-monitor-oauth` and
`oauth2-proxy-credentials` in one pass, with fresh random client secrets
for the `argocd-monitor` and `grafana` Dex clients and fresh cookie
secrets. See {doc}`manage-sealed-secrets` for the whole rebuild path.

:::{warning}
`just generate-and-seal-all` regenerates **every** cluster secret and
sets the shared admin password (the `admin-auth` Secret in
`monitoring`) to a new random value unless `ADMIN_PASSWORD` is set. It
is for a rebuild; on the running cluster,
rotate one secret at a time (A3).
:::

### A3: Rotate one secret on the running cluster

```bash
just seal-argocd-dex github    # new GitHub OAuth client ID and secret (prompts)
just seal-argocd-dex argocd    # re-derive the argo-cd client secret
just seal-argocd-dex monitor   # argocd-monitor client and cookie secrets
just seal-argocd-dex grafana   # Grafana's Dex client secret
```

Each subcommand reads the other keys from the live `argocd-dex-secret`
and keeps them, so that Secret must already exist. The `argo-cd` client
secret is not random: ArgoCD derives it from its own `server.secretkey`,
and `scripts/derive-argocd-client-secret` reproduces that derivation so
that the value in `dex.config` matches.

Commit the changed `*-secret.yaml` files and merge. Once ArgoCD has
synced them, restart the pods that read them, because a pod reads its
environment once, at start:

```bash
just restart-dex                                                  # Dex, argocd-server, repo-server
kubectl -n monitoring rollout restart statefulset/grafana-prometheus     # after `grafana`
kubectl -n argocd-monitor rollout restart deployment              # after `monitor`
```

Without the restart, Dex reports `invalid client_secret` although the
Secret objects are right.

### A4: Admin emails

Who is an admin is a list of GitHub email addresses, `admin_emails`,
which is kept in two files that must agree:

- `kubernetes-services/values.yaml`: Grafana's role mapping
  (`role_attribute_path`: Admin for these addresses, Viewer for anyone
  else) and oauth2-proxy's allowlist.
- `group_vars/all.yml`: ArgoCD's RBAC (`g, <email>, role:admin` in
  `policy.csv`; everyone else gets `role:readonly`), rendered by
  Ansible.

After changing the second, run
`ansible-playbook pb_all.yml --tags cluster`. Viewers are not listed
anywhere in the cluster: anyone the Cloudflare Access Viewers policy
lets through, who then signs in with GitHub, gets the read-only role.

### Adding a Dex static client

To put another OIDC-capable service behind Dex:

1. Add a `staticClients` entry to `dex.config` in
   `roles/cluster/tasks/argocd.yml`, with the service's redirect URI and
   `secret: $argocd-dex-secret:<name>.clientSecret`.
2. Add that key to `argocd-dex-secret` everywhere it is built:
   `scripts/generate-secrets`, `scripts/seal-from-json` and a new
   subcommand in `scripts/seal-argocd-dex`, modelled on `grafana`. A key
   missing from the Secret resolves to an empty string without an error,
   and login then fails with "Failed to get token from provider".
3. Point the service's OIDC settings at
   `https://argocd.gkcluster.org/api/dex`.
4. Run `ansible-playbook pb_all.yml --tags cluster` to apply the new
   `dex.config`, then commit and merge the sealed secret.

## Part B: oauth2-proxy

oauth2-proxy (`kubernetes-services/templates/oauth2-proxy.yaml`)
authenticates a browser with GitHub and answers ingress-nginx's
auth subrequests. It lets in only the addresses in `admin_emails`
(`authenticatedEmailsFile`, with `email_domains = []` so that the
chart's default of "any address" does not override the list), and sets
its cookie on `.gkcluster.org` so that one sign-in covers every
protected service. Sessions live in the encrypted cookie, so the two
replicas share nothing but the cookie secret.

(oauth-b1)=
### B1: The GitHub OAuth app for oauth2-proxy

1. Go to [github.com/settings/developers](https://github.com/settings/developers)
   and click **New OAuth App**.
2. Fill in the form:

   | Field | Value |
   |---|---|
   | Application name | `k3s-oauth2-proxy` (any name) |
   | Homepage URL | `https://oauth2.gkcluster.org` |
   | Authorization callback URL | `https://oauth2.gkcluster.org/oauth2/callback` |

3. Click **Register application**, copy the **Client ID** and generate a
   **Client Secret**.

On a rebuild, `just generate-and-seal-all` seals these (A2) and nothing
more is needed. B2 seals them by hand, to rotate the client secret or
the cookie secret on the running cluster.

### B2: Rotate the credentials by hand

Generate a cookie secret. oauth2-proxy uses it as raw bytes and refuses
to start unless it is 16, 24 or 32 bytes long; this prints 32
characters:

```bash
python3 -c 'import secrets; print(secrets.token_hex(16))'
```

Then seal all three values:

```bash
printf 'GitHub Client ID: ' && read -r CLIENT_ID
printf 'GitHub Client Secret: ' && read -rs CLIENT_SECRET && echo
printf 'Cookie Secret: ' && read -rs COOKIE_SECRET && echo

kubectl create secret generic oauth2-proxy-credentials \
  --namespace oauth2-proxy \
  --from-literal=client-id="$CLIENT_ID" \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --from-literal=cookie-secret="$COOKIE_SECRET" \
  --dry-run=client -o yaml | \
kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
  kubernetes-services/additions/oauth2-proxy/oauth2-proxy-secret.yaml

unset CLIENT_ID CLIENT_SECRET COOKIE_SECRET
```

Commit, merge, wait for ArgoCD to sync, then
`kubectl -n oauth2-proxy rollout restart deployment/oauth2-proxy`. A new
cookie secret signs everyone out.

### How a service is put behind oauth2-proxy

A service's ingress comes from the shared chart
`kubernetes-services/additions/ingress`. Setting `oauth2_proxy: true` in
its values adds three annotations:

```yaml
nginx.ingress.kubernetes.io/auth-url: "http://oauth2-proxy.oauth2-proxy.svc.cluster.local/oauth2/auth"
nginx.ingress.kubernetes.io/auth-signin: "https://oauth2.gkcluster.org/oauth2/start?rd=https://$host$escaped_request_uri"
nginx.ingress.kubernetes.io/auth-response-headers: "X-Auth-Request-User,X-Auth-Request-Email"
```

ingress-nginx then asks oauth2-proxy about every request, sends a
browser without a session to `oauth2.gkcluster.org` to sign in, and
passes the signed-in address to the backend as `X-Auth-Request-Email`.
The `auth-url` is the in-cluster Service on purpose: the public name
resolves to Cloudflare, which pods cannot rely on reaching.

| Service | Where it is switched on |
|---|---|
| Headlamp | `oauth2_proxy: {{ .Values.enable_oauth2_proxy }}` in `templates/dashboard.yaml`; Headlamp then asks for a ServiceAccount token (`just headlamp-token`) |
| Hubble UI | `oauth2_proxy: true` in `templates/hubble-ui.yaml`, whose Application exists only while `enable_oauth2_proxy` is on, so the UI never has an Ingress without it; it has no login of its own |
| Alertmanager | The same annotations written out in `templates/grafana.yaml` (the chart makes that ingress); Alertmanager has no login of its own |
| Minecraft dashboard | `oauth2_proxy: true`, hard-wired in `templates/minecraft.yaml` |
| scrap | `oauth2_proxy: true`, hard-wired in `templates/scrap.yaml` for the web app; its `/mcp` ingress has none and uses a bearer token |

`oauth2.gkcluster.org` must itself be reachable from the browser, so it
is one of the tunnel's hostnames (`oauth2` in `tunnel_services`,
{doc}`cloudflare-as-code`).

### The `enable_oauth2_proxy` flag

`enable_oauth2_proxy` in `kubernetes-services/values.yaml` is `true`.
Today it switches only Headlamp's ingress annotations: the oauth2-proxy
Application is always deployed, and the other three services are
hard-wired so that they fail closed (ingress-nginx returns an error when
the auth subrequest fails) instead of opening up if oauth2-proxy is
missing.

:::{note}
**Rebuild note.** The flag exists for a build that has no GitHub OAuth
apps yet: with it `false`, Headlamp is reachable behind Cloudflare
Access and its own token while the apps are created and sealed. A normal
rebuild of this cluster leaves it `true`, because the credentials are
sealed before ArgoCD creates the applications.
:::

## Check it works

The `/test-oauth-flow` Claude Code command drives a browser through
every service and reports which sign-ins pass. By hand:

1. `https://grafana.gkcluster.org`: after Cloudflare Access, click
   **Sign in with GitHub (via Dex)**. There is no password form.
2. `https://headlamp.gkcluster.org`: after Access, oauth2-proxy sends
   the browser to GitHub and back, then Headlamp asks for its token.
3. `https://alertmanager.gkcluster.org`: loads without a further prompt,
   on the cookie from step 2.

An Access prompt is Cloudflare's; a GitHub prompt after it comes from
Dex or oauth2-proxy.

## Troubleshooting

### Redirect loop on a protected service

The oauth2-proxy ingress must not itself be behind oauth2-proxy. Its
ingress is made by the oauth2-proxy chart in `templates/oauth2-proxy.yaml`
and has no `auth-url` annotation; check that none has been added:

```bash
kubectl -n oauth2-proxy get ingress oauth2-proxy -o yaml | grep auth-
```

A service with its own oauth2-proxy sidecar (argocd-monitor) needs its
own cookie name (`--cookie-name=_oauth2_proxy_monitor`): the shared
proxy's cookie reaches every subdomain, and a sidecar that tried to
validate it with its own secret would loop for ever.

### 403 after GitHub login

For Headlamp, Alertmanager, the Minecraft dashboard and scrap: the
GitHub account's email must be in `admin_emails` in `values.yaml`.
Viewers cannot use these services, by design.

For ArgoCD, Grafana and argocd-monitor: any GitHub user who got past
Cloudflare Access can sign in, as a viewer. A 403 there comes from the
service's own roles (A4).

### 500 on every protected service

ingress-nginx could not complete the auth subrequest. Check that the
oauth2-proxy pods are running and that the ingress's `auth-url` is the
in-cluster Service address shown above.

### Login fails right after a reseal

`invalid client_secret` or "Failed to get token from provider" after
sealing means a pod still holds the old value, or a key is missing from
`argocd-dex-secret`. Restart the pods (A3). If it persists, check that
the Secret has the label `app.kubernetes.io/part-of: argocd`, without
which ArgoCD does not resolve `$argocd-dex-secret:<key>` and passes the
literal text to GitHub (a 404 at GitHub):

```bash
kubectl -n argo-cd get secret argocd-dex-secret --show-labels
```

### oauth2-proxy crash-loops at start

Its cookie secret is not 16, 24 or 32 bytes. Generate it with
`secrets.token_hex(16)` (B2), not with base64 of 32 random bytes, which
is 44 characters.

### A service loads without a login

Check that the annotations are on its Ingress:

```bash
kubectl get ingress -n <namespace> <service>-ingress -o yaml | grep auth-
```

For Headlamp, also check that `enable_oauth2_proxy` is `true`.

### OIDC discovery returns HTML or a 404

A Dex client must be given the full discovery URL,
`https://argocd.gkcluster.org/api/dex/.well-known/openid-configuration`:
`/api/dex` redirects to `/api/dex/`, which is a 404, and some OIDC
libraries do not follow the redirect.

If the discovery document comes back as HTML (`expected Content-Type =
application/json, got "text/html"`), the pod's request went out to
Cloudflare and met the Access login page. Inside the cluster,
`argocd.gkcluster.org` must resolve to ingress-nginx's ClusterIP: the
`coredns-custom` ConfigMap that does this is written by
`ansible-playbook pb_all.yml --tags cluster`.

### Dex rejects the redirect URI

The redirect URIs in `dex.config` are `https://` only. A service behind
the tunnel receives plain HTTP from ingress-nginx and may build an
`http://` callback from it. Tell the service its public URL, as
Grafana's `root_url` and argocd-monitor's `--redirect-url` do, so that
the callback it sends matches the one registered.
