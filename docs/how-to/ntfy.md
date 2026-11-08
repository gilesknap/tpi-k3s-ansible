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
| `behind-proxy: true`, `proxy-forwarded-header: CF-Connecting-IP` | Visitor rate limits (ntfy defaults) apply per real client, not to the tunnel |

There is one account per sender, each with an access token, and the access
list grants each the least it needs:

| User | Role | Access | Used by |
|---|---|---|---|
| `alertmanager` | user | write-only on `cluster-alerts` | the Alertmanager bridge |
| `vps` | user | write-only on `vps-alerts` | the VPS |
| `phone` | user | read-only on `cluster-alerts` and `vps-alerts` | the phone app |
| `admin` | admin | every topic | the owner, for tests and administration |

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
- `ntfy-auth` also holds the plain admin password and each token
  (`admin-password`, `<user>-token`), so they can be read back for clients
  and kept across a rebuild. The client users' passwords are random and
  discarded: they authenticate with tokens only.

The NetworkPolicy admits only `ingress-nginx` (the `allowed_namespaces`
value), so nothing else in the cluster can reach the pod directly. An
in-cluster publisher, such as the Alertmanager bridge, adds its namespace
there.

### State

Both of ntfy's SQLite databases are on the pod's `emptyDir`, so the pod is
not pinned to a node and moves freely, for example when a node is drained
or fenced:

- The **user database** (`auth-file`) is rebuilt from the declarative
  configuration at every start, so nothing in it needs to persist.
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

2. Add the tunnel hostname and the Access bypass (below).

3. Let ArgoCD sync the `ntfy` Application, then check:

   ```bash
   curl https://ntfy.<domain>/v1/health     # {"healthy":true,...}
   curl -d test https://ntfy.<domain>/vps-alerts   # 403: anonymous is denied
   ```

### Cloudflare

The tunnel's public hostnames are managed in the Cloudflare dashboard, not
in this repository. In the [Cloudflare dashboard](https://dash.cloudflare.com/):

1. **Tunnel route.** Under **Networking → Tunnels**, open the tunnel,
   **Routes → Add route**, and add the public hostname, as in
   {doc}`cloudflare-web-tunnel`:

   | Subdomain | Domain | URL |
   |---|---|---|
   | `ntfy` | `<domain>` | `http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local` |

   If an A record for `ntfy` already exists, delete it first so the tunnel
   can create its CNAME.

2. **Access bypass.** The wildcard Access application covers every
   subdomain, and the phone app cannot complete an Access login. Add an
   Access application for `ntfy.<domain>` whose policy Action is
   **Bypass** and Include **Everyone**, as in
   [Bypass application for API endpoints](cloudflare-web-tunnel.md#bypass-application-for-api-endpoints).
   The more specific application takes precedence over the wildcard; check
   in the dashboard that it does.

3. **Rate limit (recommended).** As the hostname is open to the internet,
   add a WAF rate-limiting rule for it under **Security → WAF → Rate
   limiting rules**: for example, requests where *Hostname equals
   `ntfy.<domain>`*, counted per IP, blocked above about 100 requests a
   minute. ntfy's own per-visitor limits still apply behind it.

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

Keep the **vps** token in a file only root can read:

```bash
sudo install -m 600 -o root -g root /dev/null /etc/ntfy-token
sudoedit /etc/ntfy-token        # paste the vps token, one line
```

Then, from a root cron job, systemd unit or script:

```bash
TOKEN=$(cat /etc/ntfy-token)
curl -fsS -H "Authorization: Bearer $TOKEN" \
  -H "Title: backup failed" -H "Priority: high" \
  -d "nightly backup on $(hostname) exited 1" \
  https://ntfy.<domain>/vps-alerts
```

The token can only publish to `vps-alerts`; a leaked copy cannot read
anything or publish to other topics.

## Revoking or rotating tokens

Rotate one token (or `admin`, or `all`) with:

```bash
just seal-ntfy --rotate vps
```

This generates a new value for that user only, keeps the others, and
re-seals `ntfy-auth`. Commit and push, wait for ArgoCD to sync the Secret,
then restart the pod so ntfy re-provisions from the new values:

```bash
kubectl delete pod -n ntfy -l app.kubernetes.io/name=ntfy
```

The old token stops working as soon as the new pod starts, since a
provisioned token that is no longer configured is removed. Give the
client its new token (`just ntfy-tokens`).

To revoke a sender for good, remove the user from `USERS` and
`TOKEN_USERS` in `scripts/lib/ntfy_auth.py` and its entries from `access`
in `kubernetes-services/additions/ntfy/values.yaml`, then re-seal, commit
and restart as above. To add a sender, do the reverse: add the user and its
access, then `just seal-ntfy` generates its token.

## Rebuilds

`scripts/export-external-creds` exports `NTFY_ADMIN_PASSWORD`,
`NTFY_ALERTMANAGER_TOKEN`, `NTFY_VPS_TOKEN` and `NTFY_PHONE_TOKEN` from the
running cluster, and `just generate-and-seal-all` seals them into
`ntfy-auth` on the new cluster, so the phone and the VPS keep working.
Any of them left unset is generated, and a warning says so. To rotate a
token during a rebuild, remove its line from `.env`.

## Monitoring

Add an external uptime check, from outside the cluster and the home
network, on `https://ntfy.<domain>/v1/health` (it needs no token and
returns `{"healthy":true}`). If ntfy is down, alerts cannot reach the
phone, so this check should alert through some other channel, such as
the uptime service's own email.
