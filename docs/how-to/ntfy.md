# Push Notifications with ntfy

[ntfy](https://ntfy.sh) is a small publish/subscribe server for push
notifications. A sender POSTs a message to a topic over HTTPS; the ntfy
phone app, subscribed to that topic, shows it as a notification. This
repository runs a self-hosted, locked-down ntfy at `ntfy.<domain>` for:

- notifications to the owner's Android phone;
- cluster alerts (an Alertmanager bridge publishing to `cluster-alerts`);
- alerts from hosts outside the cluster, such as a VPS, publishing to
  `vps-alerts` over HTTPS.

The cluster wiring is:

- An ArgoCD Application (`kubernetes-services/templates/ntfy.yaml`).
- A small local chart (`kubernetes-services/additions/ntfy/`) with the
  Deployment, Service, the `server.yml` ConfigMap, a NetworkPolicy and the
  `ntfy-auth` SealedSecret.
- An ingress for `ntfy.<domain>` through the Cloudflare tunnel, with no
  oauth2-proxy and no Cloudflare Access.

## Security model

ntfy's own authentication is the only gate, so the server is locked down:

| Setting | Effect |
|---|---|
| `auth-default-access: deny-all` | Anonymous clients can neither publish nor subscribe |
| `enable-signup: false`, `enable-login: false` | No accounts can be created and there is no browser login |
| `web-root: disable` | No web app; the server is an API only |
| no `attachment-cache-dir` | Attachments are off; messages are text, at most 4 KB |
| `behind-proxy: true`, `proxy-forwarded-header: CF-Connecting-IP` | For tunnel traffic, visitor rate limits (ntfy defaults) apply per real client, not to the tunnel (but see the caveat below) |
| `visitor-message-daily-limit: 500` | At most 500 messages a day per visitor, so a leaked token cannot push thousands a day from one address |

There is one account per sender, each with an access token, and the access
list grants each the least it needs:

| User | Access | Used by |
|---|---|---|
| `alertmanager` | write-only on `cluster-alerts` | the Alertmanager bridge |
| `vps` | write-only on `vps-alerts` | the VPS |
| `phone` | read-only on `cluster-alerts` and `vps-alerts` | the phone app |

There is no admin user: auth is declarative, so nothing needs one, and it
would be an internet-facing password login.

Auth is **declarative**: since 2.14, ntfy provisions users, access entries
and tokens from its configuration at every start (`auth-users`,
`auth-access`, `auth-tokens`), and removes any provisioned entry that is no
longer configured. Nobody runs `ntfy user add`.

- The users (with bcrypt password hashes) and the tokens are secret. They
  are in the `ntfy-auth` SealedSecret as `NTFY_AUTH_USERS` and
  `NTFY_AUTH_TOKENS`, which the pod reads as environment variables.
- The access list is not secret. It is in
  `kubernetes-services/additions/ntfy/values.yaml` (`access`) and rendered
  into `server.yml`.
- `ntfy-auth` also holds each plain token (`<user>-token`), so it can be
  read back for clients and kept across a rebuild. The users' passwords
  are random and discarded: they authenticate with tokens only.
- The user names are listed once, in `SENDERS` in
  `scripts/lib/ntfy_auth.py`; every script derives them from there.

The NetworkPolicy admits only `ingress-nginx` (the `allowed_namespaces`
value) to the pod. An in-cluster publisher, such as the Alertmanager
bridge, adds its namespace there. This limits who reaches the pod
*directly*; anything that can reach ingress-nginx can still talk to ntfy
through it, so ntfy's token auth is the real gate.

:::{warning}
`CF-Connecting-IP` is trusted from anyone who reaches ingress-nginx. On the
tunnel path Cloudflare's edge sets it, but a LAN host (through
ingress-nginx's LoadBalancer IPs) or a pod (through its ClusterIP) can send
any value, and so dodge the per-IP rate limits and the daily cap. ntfy
counts users without a tier per IP, so the daily cap is also per address,
not per account: a leaked token used from many addresses gets 500 messages
a day from each. Spoofing the header grants no access; it only evades the
limits.
:::

### State

Both of ntfy's SQLite databases are on the pod's `emptyDir`, so the pod is
not pinned to a node and moves freely, for example when a node is drained
or fenced:

- The **user database** (`auth-file`) is provisioned from the declarative
  configuration at every start, so nothing in it needs to persist. A new
  pod starts with an empty one.
- The **message cache** (`cache-file`, `cache-duration: 12h`) only serves
  messages to clients that were offline when they were sent. A pod move
  loses at most the messages an offline phone has not yet fetched;
  Alertmanager re-sends firing alerts on its `repeat_interval`.

Keeping ntfy movable matters more than keeping the cache: the alerts it
carries are often about a node going down, and a pod pinned to that node's
local volume could not deliver them. SQLite is never put on NFS.

## Deploy

1. Seal the users and tokens, if `ntfy-auth-secret.yaml` does not exist
   yet (a fork) or the cluster's sealing key has changed:

   ```bash
   just seal-ntfy
   ```

   It keeps every value already in the live `ntfy-auth` Secret and generates
   the rest, then seals the result into
   `kubernetes-services/additions/ntfy/templates/ntfy-auth-secret.yaml`.
   No value is printed. Commit and push it. A cluster rebuild does this
   for you (see [Rebuilds](#rebuilds)).

2. Add the tunnel route, the Access bypass and the rate limit
   (see [Cloudflare](#cloudflare) below).

3. Let ArgoCD sync the `ntfy` Application, then check:

   ```bash
   curl https://ntfy.<domain>/v1/health     # {"healthy":true,...}
   curl -d test https://ntfy.<domain>/vps-alerts   # 403: anonymous is denied
   ```

### Cloudflare

The edge configuration for ntfy is in `cloudflare/` (see
{doc}`cloudflare-as-code`), and `just cf-apply` sets it up:

- **Tunnel route and DNS record:** the `ntfy` entry in `tunnel_services`
  (`cloudflare/locals.tf`), routed to ingress-nginx like the other
  services.
- **Access bypass:** the wildcard Access application covers every
  subdomain, and the phone app cannot complete an Access login. The
  `ntfy` application in `cloudflare/access.tf` uses the reusable
  `bypass` policy; it is more specific than the wildcard, so it takes
  precedence for `ntfy.<domain>`.
- **Rate limit:** as the hostname is open to the internet, a WAF
  rate-limiting rule (`cloudflare/waf.tf`) blocks, for 10 seconds, a
  client IP that sends more than 17 requests in 10 seconds (about 100 a
  minute) to ntfy's topic paths (including comma-joined topics),
  `/v1/` or `/`. These are the Free plan's limits, which also rule out
  matching on the hostname, so the rule matches those paths on every
  host in the zone instead. Requests to other paths, such as an unknown
  topic, are not counted; ntfy denies them. Keep the rule's topic list
  in step with `access` in
  `kubernetes-services/additions/ntfy/values.yaml`. ntfy's own
  per-visitor limits still apply behind it.

If you do not manage Cloudflare with that code, make the same three
changes in the [dashboard](https://dash.cloudflare.com/): a tunnel
route for `ntfy.<domain>` to
`http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local`
(delete any existing `ntfy` A record first, so the tunnel can create its
CNAME; see {doc}`cloudflare-web-tunnel`); a self-hosted Access
application for `ntfy.<domain>` with a policy of Action **Bypass** and
Include **Everyone**, as in
[Bypass application for API endpoints](cloudflare-web-tunnel.md#bypass-application-for-api-endpoints);
and a rate-limiting rule under **Security → WAF → Rate limiting rules**
like the one above.

## Android app

1. Install the ntfy app from Google Play or F-Droid.
2. Print the server URL and the tokens, in your own terminal (the command
   only reads the live Secret):

   ```bash
   just ntfy-tokens
   ```

3. In the app, open **Settings → Advanced → Custom headers** and add a
   header for the server `https://ntfy.<domain>`: name `Authorization`,
   value `Bearer <phone token>`. The app sends it on every request to that
   server.
4. Under **Settings → Default server**, set `https://ntfy.<domain>`.
5. Subscribe to `cluster-alerts` and `vps-alerts`, using the server above.

:::{note}
Do not use **Settings → Manage users** for the token: that dialog needs a
username and sends a username and password, while ntfy reads a token only
from a Bearer header (or from Basic auth with an *empty* username). The
app does not allow both a configured user and a custom `Authorization`
header for the same server.
:::

Android connects to the server directly, so no `upstream-base-url` is
needed. For a self-hosted server the app keeps its own connection open
("instant delivery", shown as a permanent notification), since the Google
Play build uses Firebase only for ntfy.sh; leave that service on, or
messages may arrive late.

:::{note}
**iOS** cannot hold a connection open in the background. Apple's push
service has to wake the app, and only ntfy.sh can send through it. An iOS
client needs `upstream-base-url: "https://ntfy.sh"` in `server.yml`
(`templates/configmap.yaml`): ntfy then sends ntfy.sh a poll request
carrying only the message ID, and the app fetches the message from this
server.
:::

## Publishing from a VPS

Keep the **vps** token in a file only root can read, as the whole header
line, so it is never on a command line (where `ps` would show it):

```bash
sudo install -m 600 -o root -g root /dev/null /etc/ntfy-header
sudoedit /etc/ntfy-header
# one line:  Authorization: Bearer <vps token>
```

Then, from a root cron job, systemd unit or script (`-H @file` needs curl
7.55 or later):

```bash
curl -fsS -H @/etc/ntfy-header \
  -H "Title: backup failed" -H "Priority: high" \
  -d "nightly backup on $(hostname) exited 1" \
  https://ntfy.<domain>/vps-alerts
```

The token can only publish to `vps-alerts`; a leaked copy cannot read
anything or publish to other topics.

## Revoking or rotating tokens

Rotate one token (or `all`) with:

```bash
just seal-ntfy --rotate vps
```

This generates a new token for that user only, keeps the others, and
re-seals `ntfy-auth`. Commit and push, wait for ArgoCD to sync the Secret,
then **recreate the pod** (delete it; do not just restart the container):

```bash
kubectl delete pod -n ntfy -l app.kubernetes.io/name=ntfy
```

Recreating matters because any token holder can mint extra tokens for its
own user through ntfy's account API (`POST /v1/account/token`, with an
expiry of its choosing). Those tokens are not provisioned: they live only
in the user database on the pod's `emptyDir`, which survives a container
restart but not a new pod. A new pod starts with an empty database and
provisions only the configured tokens, so the old token and anything
minted from it stop working. Give the client its new token
(`just ntfy-tokens`).

The user names are listed once, in `SENDERS` in
`scripts/lib/ntfy_auth.py`. Every script (sealing, the rebuild export and
generation, `just ntfy-tokens`) derives them from there.

- **To add a sender:** add it to `SENDERS` (with `"owner"` if you hand its
  token out yourself, `"cluster"` for an in-cluster publisher), add its
  topic grants to `access` in `kubernetes-services/additions/ntfy/values.yaml`,
  run `just seal-ntfy` (which generates its token), commit, push and
  recreate the pod.
- **To revoke a sender for good:** remove it from `SENDERS` and its
  entries from `access`, then re-seal, commit, push and recreate the pod.

## Rebuilds

`scripts/export-external-creds` exports one `NTFY_<USER>_TOKEN` per user
(for example `NTFY_PHONE_TOKEN`) from the running cluster, and
`just generate-and-seal-all` seals them into `ntfy-auth` on the new
cluster, so the phone and the VPS keep working. Any left unset is
generated, and a warning says so. To rotate a token during a rebuild,
remove its line from `.env`.

## Monitoring

Add an external uptime check, from outside the cluster and the home
network, on `https://ntfy.<domain>/v1/health` (it needs no token and
returns `{"healthy":true}`). If ntfy is down, alerts cannot reach the
phone, so this check should alert through some other channel, such as
the uptime service's own email.
