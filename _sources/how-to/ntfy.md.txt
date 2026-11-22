# Push notifications with ntfy

[ntfy](https://ntfy.sh) is a small publish/subscribe server for push
notifications. A sender POSTs a message to a topic over HTTPS; the ntfy
phone app, subscribed to that topic, shows it as a notification. The
cluster runs its own locked-down ntfy at `ntfy.gkcluster.org`, so that
alerts reach the owner's Android phone without passing through a
third-party service. It carries two topics:

- `cluster-alerts`: Alertmanager's pushes (see {doc}`monitoring` for
  which alerts are routed there), and scrap's notices when its Claude
  ingest pauses (see {ref}`ntfy-scrap`);
- `vps-alerts`: alerts from the VPS, published over HTTPS from outside
  the cluster.

The cluster wiring is:

- An ArgoCD Application (`kubernetes-services/templates/ntfy.yaml`).
- A small local chart (`kubernetes-services/additions/ntfy/`) with the
  Deployment, Service, the `server.yml` ConfigMap, a NetworkPolicy and the
  `ntfy-auth` SealedSecret.
- An HTTPRoute on Cilium's Gateway for `ntfy.gkcluster.org`, reached through
  the Cloudflare Tunnel, with no oauth2-proxy and no Cloudflare Access login,
  because the phone app can complete neither. It sets no request timeout
  (`gateway_request_timeout: 0s`), as a subscription is a long-lived stream,
  and Envoy streams it without buffering.

The pod runs `binwiederhier/ntfy:v2.34.0` (the `image` value in
`kubernetes-services/additions/ntfy/values.yaml`), one replica with the
`Recreate` strategy, on whichever node the scheduler picks.

## Security model

ntfy's own authentication is the only gate, so the server is locked down:

| Setting | Effect |
|---|---|
| `auth-default-access: deny-all` | Anonymous clients can neither publish nor subscribe |
| `enable-signup: false`, `enable-login: false`, `enable-reservations: false` | No accounts can be created, there is no browser login and no topic can be reserved |
| `web-root: disable` | No web app; the server is an API only |
| no `attachment-cache-dir` | Attachments are off; messages are text, at most 4 KB |
| `behind-proxy: true`, `proxy-forwarded-header: CF-Connecting-IP` | For tunnel traffic, visitor rate limits (ntfy defaults) apply per real client, not to the tunnel (but see the caveat below) |
| `visitor-message-daily-limit: 500` | At most 500 messages a day per visitor, so a leaked token cannot push thousands a day from one address |

There is one account per sender, each with an access token, and the access
list grants each the least it needs:

| User | Access | Used by |
|---|---|---|
| `alertmanager` | write-only on `cluster-alerts` | Alertmanager |
| `scrap` | write-only on `cluster-alerts` | scrap ({doc}`scrap`) |
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

The NetworkPolicy admits only the Alertmanager pods in `monitoring` and the
scrap pods in `scrap` (`allowed_pods`), which publish to the Service
directly, and the `ntfy-from-gateway` CiliumNetworkPolicy admits Cilium's
Gateway. Another in-cluster publisher adds its pods to `allowed_pods`. This
limits who reaches the pod *directly*; anything that can reach the Gateway
can still talk to ntfy through it, so ntfy's token auth is the real gate.

:::{warning}
`CF-Connecting-IP` is trusted from anyone who reaches the Gateway. On the
tunnel path Cloudflare's edge sets it, but a LAN or tailnet host (through the
node addresses) or a pod (through the Gateway's ClusterIP) can send
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

ntfy is deployed and has no enable flag: the `ntfy` Application is always
part of the cluster. These are the steps that put it there, and that
check it after a change.

1. Seal the users and tokens. This is needed only when
   `ntfy-auth-secret.yaml` does not decrypt on the cluster (it was sealed
   for another one) or a sender has been added:

   ```bash
   just seal-ntfy
   ```

   It keeps every value already in the live `ntfy-auth` Secret and generates
   the rest, then seals the result into
   `kubernetes-services/additions/ntfy/templates/ntfy-auth-secret.yaml`,
   Alertmanager's copy of its token into
   `kubernetes-services/additions/grafana/alertmanager-ntfy-secret.yaml`
   and scrap's into
   `kubernetes-services/additions/scrap/templates/scrap-ntfy-secret.yaml`.
   No value is printed. Commit and push all three. A cluster rebuild does this
   by itself (see [Rebuilds](#rebuilds)).

2. Apply the tunnel route, the Access bypass and the rate limit
   (see [Cloudflare](#cloudflare) below).

3. Let ArgoCD sync the `ntfy` Application, then check:

   ```bash
   curl https://ntfy.gkcluster.org/v1/health     # {"healthy":true,...}
   curl -d test https://ntfy.gkcluster.org/vps-alerts   # 403: anonymous is denied
   ```

### Cloudflare

ntfy's edge configuration is three pieces of code in `cloudflare/`,
applied with `just cf-apply` ({doc}`cloudflare-as-code`):

- **Tunnel route and DNS record** (`locals.tf`): the entry
  `{ name = "ntfy", access_bypass = true }` in `tunnel_services`, routed
  to Cilium's Gateway like every other service.
- **Access bypass** (`access.tf`): the `clusterapps` wildcard application
  puts a browser login in front of every subdomain, which the phone app
  and `curl` cannot complete. The `ntfy` application, for exactly
  `ntfy.gkcluster.org`, uses the reusable `bypass` policy; it is more
  specific than the wildcard, so it wins for this hostname. The
  `access_bypass = true` flag is what allows it: without the flag,
  `access_guard.tf` fails the plan for any application that lets everyone
  in ({ref}`cf-access-bypass`).
- **Rate limit** (`waf.tf`): as the hostname is open to the internet, the
  zone's rate-limiting rule blocks, for 10 seconds, a client IP that
  sends more than 17 requests in 10 seconds (about 100 a minute) to
  ntfy's topic paths (`/cluster-alerts*` and `/vps-alerts*`, which also
  covers `/json`, `/sse`, `/ws` and comma-joined topics), `/v1/*` or `/`.
  These are the Free plan's limits, which also rule out matching on the
  hostname, so the rule matches those paths on every host in the zone.
  Requests to other paths, such as an unknown topic, are not counted;
  ntfy denies them. ntfy's own per-visitor limits still apply behind it.

:::{important}
The topic names are written in three places that must agree: `access`
in `kubernetes-services/additions/ntfy/values.yaml` (who may use a
topic), `ntfy_topics` in `cloudflare/waf.tf` (the rate limit), and the
publishers themselves. A new topic needs all three, then `just cf-apply`.
:::

## Android app

1. Install the ntfy app from Google Play or F-Droid.
2. Print the server URL and the tokens, in the owner's own terminal and
   not through a Claude session, as the output is secret (the command only
   reads the live Secret):

   ```bash
   just ntfy-tokens
   ```

3. In the app, open **Settings → Advanced → Custom headers** and add a
   header for the server `https://ntfy.gkcluster.org`: name `Authorization`,
   value `Bearer <phone token>`. The app sends it on every request to that
   server.
4. Under **Settings → Default server**, set `https://ntfy.gkcluster.org`.
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

## Cluster alerts from Alertmanager

Alertmanager (kube-prometheus-stack) publishes to `cluster-alerts` with a
`webhook_configs` receiver; {doc}`monitoring` lists what is pushed. ntfy
turns Alertmanager's webhook JSON into a notification itself, with no
bridge component:

- The publish URL is
  `http://ntfy.ntfy.svc.cluster.local/cluster-alerts?template=alertmanager-cluster&click=...`.
  `template=` names a message template, which ntfy renders as Go templates
  (with sprig functions) over the JSON body, into the title, message and
  priority.
- The template is
  `kubernetes-services/additions/ntfy/files/alertmanager-cluster.yml`,
  mounted from the `ntfy-templates` ConfigMap at `template-dir`
  (`/etc/ntfy-templates`). ntfy reads it on every publish, so an edit
  needs no restart. ntfy's own built-in `alertmanager` template sets no
  priority and links to Prometheus's internal address, hence this one.
- ntfy rejects a rendered message over 4 KB (and Alertmanager then drops
  that notification), so the template truncates annotations and the
  receiver sends at most 5 alerts (`max_alerts`) per notification.
- The `alertmanager` token reaches Alertmanager as the `alertmanager-ntfy`
  Secret in `monitoring`, a copy of `ntfy-auth`'s `alertmanager-token`
  (`CLUSTER_COPIES` in `scripts/lib/ntfy_auth.py`). `just seal-ntfy`,
  including `--rotate alertmanager`, and the rebuild seal the copy along
  with `ntfy-auth`. After a rotation, recreate the ntfy pod as soon as both
  have synced: Alertmanager uses the new token straight away, and ntfy
  rejects it (and so drops those alerts) until the new pod starts.

(ntfy-scrap)=
## Notices from scrap

scrap ({doc}`scrap`) announces trouble with one plain POST to
`SCRAP_NOTIFY_URL`: the first pause of an episode of its Claude ingest
(credit, auth, budget or an outage), gc gathering orphaned files onto a
page, a failed scheduled job, and Litestream replication stalling or
recovering. Each is a fixed line of text, sent to `cluster-alerts` at the
default priority, so it reaches the phone beside the cluster alerts.

scrap sends no headers of its own (`urllib` with only a body), so its token
travels in the URL instead, in ntfy's `auth` query parameter: the value of
the `Authorization` header, `Bearer <token>`, base64url-encoded without
padding. The URL is

```text
http://ntfy.ntfy.svc.cluster.local/cluster-alerts?auth=<base64url("Bearer <scrap token>")>
```

over the in-cluster Service, which ntfy's NetworkPolicy admits from the scrap
pods (`allowed_pods`); scrap has no egress policy.

- The URL is the `url` key of the `scrap-ntfy` Secret in `scrap`, the
  `CLUSTER_COPIES` copy of `ntfy-auth`'s `scrap-token`, built from the topic
  URL in `COPY_URLS` (`scripts/lib/ntfy_auth.py`). `just seal-ntfy` and the
  rebuild seal it with `ntfy-auth`, so it never needs editing by hand.
- The scrap Application (`kubernetes-services/templates/scrap.yaml`) sets
  `SCRAP_NOTIFY_URL` from it through `extraEnv`, in the app and the jobs
  container. It does not use the chart's `ingest.notifyUrlKey`, which must
  name a key of `scrap-secrets`, a Secret sealed by hand. The reference is
  optional: without the Secret, scrap runs and announces nothing.
- The token can only publish to `cluster-alerts`. Being in a URL, it can
  show up wherever the URL is logged; scrap logs only "notification
  failed", never the URL.

scrap reads the URL at start: after its token is rotated
(`just seal-ntfy --rotate scrap`) and both Secrets have synced, recreate the
ntfy pod and then restart scrap
(`kubectl -n scrap rollout restart deploy/scrap`).

To send a test notice as scrap, from the running pod, without printing the
URL:

```bash
kubectl exec -n scrap deploy/scrap -c scrap -- \
  python -c 'from scrap.notify import notify; notify("scrap: test notice")'
```

It logs "notification failed" if the POST did not go through.

## Publishing from the VPS

The VPS publishes its own alerts to `vps-alerts` over the public
hostname, with the `vps` user's token. The token is kept in a file only
root can read, as the whole header line, so it is never on a command line
(where `ps` would show it):

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
  https://ntfy.gkcluster.org/vps-alerts
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

- **To add a sender:** add it to `SENDERS` (with `"owner"` if its token is
  handed out by hand, `"cluster"` for an in-cluster publisher, which also
  needs a `CLUSTER_COPIES` entry if it runs outside the `ntfy` namespace, and
  a `COPY_URLS` entry if it can only POST to a URL, as scrap does), add its
  topic grants to `access` in `kubernetes-services/additions/ntfy/values.yaml`,
  run `just seal-ntfy` (which generates its token), commit, push and
  recreate the pod.
- **To revoke a sender for good:** remove it from `SENDERS` and its
  entries from `access`, then re-seal, commit, push and recreate the pod.

## Rebuilds

`scripts/export-external-creds` exports one `NTFY_<USER>_TOKEN` per user
(for example `NTFY_PHONE_TOKEN`) from the running cluster, and
`just generate-and-seal-all` seals them into `ntfy-auth` on the new
cluster, so the phone and the VPS keep working (`NTFY_SCRAP_TOKEN`, like
`NTFY_ALERTMANAGER_TOKEN`, only needs to match its in-cluster copy, which
the rebuild seals from the same value). Any left unset is
generated, and a warning says so. To rotate a token during a rebuild,
remove its line from `.env`.

## Monitoring

ntfy cannot report its own failure: if it is down, no alert reaches the
phone. `https://ntfy.gkcluster.org/v1/health` needs no token and returns
`{"healthy":true}`, so it suits an uptime check run from outside the
cluster and the home network, alerting through some other channel such
as the uptime service's own email. No such check is defined in this
repo.
