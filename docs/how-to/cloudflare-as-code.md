# Manage Cloudflare as Code (OpenTofu)

The cluster's edge configuration at Cloudflare (DNS records, the tunnel's
public hostnames, Zero Trust Access applications and policies, zone
security settings, cache rules and rate-limiting rules) is described in
`cloudflare/` as [OpenTofu](https://opentofu.org) code using the
[Cloudflare provider](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs).
Changes are made in the repo and reviewed like any other change, then
applied by the owner with `just cf-apply`, rather than clicked in the
dashboard.

:::{note}
The other Cloudflare guides ({doc}`cloudflare-tunnel`,
{doc}`cloudflare-web-tunnel`, {doc}`cloudflare-ssh-tunnel`) describe the
dashboard steps. Once you manage Cloudflare with this code, make the same
changes in `cloudflare/` instead: a change made in the dashboard shows up
as drift in the next `just cf-plan`, and `just cf-apply` reverts it.
:::

## What is managed

| File | Contents |
|------|----------|
| `locals.tf` | `tunnel_services`: the list of public services. Each entry is a tunnel ingress rule (in list order, before the 404 catch-all) and a proxied CNAME to the tunnel; `cache = true` adds a cache rule for it; `access_bypass = true` puts it on the Access bypass allowlist |
| `tunnel.tf` | The remotely-managed tunnel, its secret (and so the tunnel token, output `tunnel_token`) and its ingress configuration |
| `dns.tf` | The tunnel CNAMEs, plus `dns_only_records` (records that bypass the tunnel) |
| `access.tf` | Reusable policies (Owner, Viewers, bypass, service token) and the Access applications |
| `access_guard.tf` | The rule that every public hostname is behind Access unless allowlisted (see [below](#every-public-hostname-in-the-code-is-behind-access)) |
| `zone.tf` | Zone settings (SSL mode, minimum TLS, HSTS, security level, ...) and the zone's cache rules |
| `waf.tf` | The zone's rate-limiting rules (the `http_ratelimit` ruleset) |
| `imports.tf` | `import` blocks that adopt existing objects into state |
| `variables.tf` | Per-account inputs; the values go in the gitignored `live.auto.tfvars` |

### Login methods are set up in the dashboard

The Access login methods (identity providers) are **not** managed here:
Cloudflare never returns an OAuth client secret through its API, so code
cannot keep a login method in step with what is live. Set them up once in
the Zero Trust dashboard under **Settings > Authentication > Login
methods**:

- **One-time PIN** (emailed code; no configuration).
- **GitHub**, with the client ID and secret of a GitHub OAuth app whose
  callback URL is `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback`.

The Owner policy requires the GitHub login method and finds it by name
(`owner_login_method`, default `GitHub`); a plan fails with a clear error
if no login method of that name exists. A rebuild into a fresh Cloudflare
account therefore means adding both login methods by hand **before** the
first `just cf-apply`.

### Also not managed

Cloudflare's managed rulesets (DDoS, the free managed WAF
ruleset), zone settings left at their defaults, and the Access service
token's lifecycle. The service token is looked up by name: its secret is
shown only once, when it is created, and has to be handed to the client,
so create or rotate it in the Zero Trust dashboard (**Access > Service
auth**). Nor are the zone's
(empty) custom WAF ruleset, the Zero Trust organization settings, and the
Access apps' `eager_redirect_cookie_setting`, which the provider's schema
does not have: check it in the dashboard after changing one of those apps.

To add a service to the edge, add an entry to `tunnel_services` (and, if
it needs something other than the wildcard Owner app, an entry in
`local.access_apps` in `access.tf`), then plan and apply. ntfy is an
example of both: a `tunnel_services` entry with `access_bypass = true`,
an Access app with the `bypass` policy (a more specific app than the
wildcard, so it wins for that hostname), and a rate-limiting rule in
`waf.tf` (see {doc}`ntfy`).

### Every public hostname in the code is behind Access

The repo is public, so a hostname left open by mistake is easy for
anyone to find. `access_guard.tf` makes `tofu plan` (and so
`just cf-plan` and `just cf-apply`) fail, before anything reaches
Cloudflare, when:

- a tunnel service, or a proxied entry in `dns_only_records`, is not
  covered by an Access app whose policies all ask for an identity or a
  service token. The `*.<domain>` wildcard app covers every hostname one
  label below the domain (`a.<domain>`, not `a.b.<domain>`); an app for
  exactly one hostname covers that hostname; an app with a path
  (such as `scrap.<domain>/mcp`) covers only that path, never the whole
  hostname. The error reads `<host> is routed through the tunnel but no
  Access app protects it`.
- an Access app lets anyone in (a policy with the `bypass` decision, or
  one that includes everyone, a login method on its own or the whole
  internet's IP range) for a hostname that is not on the bypass
  allowlist. One such policy opens the whole app, as Cloudflare evaluates
  bypass policies first. The error reads `Access app "<name>" lets anyone
  in ... which is not on the bypass allowlist`. This also catches a
  bypass app with a path, and a bypass policy added to the wildcard app.

The allowlist is the `tunnel_services` entries with
`access_bypass = true`: services that are public on purpose, such as
static pages or ntfy, which does its own token auth. It lives in the
code, next to the services, so that opening a service to the internet is
a visible line in a reviewed change. A service-token-only policy (the
`non_identity` decision) counts as protected, not as bypass. A
hostname on the allowlist is not checked at all, so it may have a bypass
app or none. Only tunnel services can be allowlisted: a proxied
`dns_only_records` entry must always be behind Access.

The guard sees only this code. It does not judge rules that are wide by
their values (a public email domain in `viewer_email_domains`, say), and
it knows nothing of hostnames created outside `cloudflare/`.

To fix either error, add or correct the Access app in `access.tf`; or,
if the service really is meant to be public, set `access_bypass = true`
on its `tunnel_services` entry. A flag that no open app needs gives a
warning (not an error), so the allowlist does not outgrow its use.

### Rate limiting on the Free plan

Cloudflare's Free plan allows one rate-limiting rule, with a 10-second
counting period and a 10-second block, counted per client IP, and an
expression that may only use the URI path (and Verified Bot), not the
hostname. The rule in `waf.tf` fits those limits: it matches ntfy's
topic paths, `/v1/` and `/` (on every host in the zone, as it cannot
name one), allows 17 requests in 10 seconds (about 100 a minute) per
IP, then blocks for 10 seconds. The zone's one rule is then taken, so a
second rule, for another service, needs a paid plan. On a paid plan you can match on the hostname and
use longer periods; see Cloudflare's
[rate limiting rules](https://developers.cloudflare.com/waf/rate-limiting-rules/)
for what each plan allows. Only the edit token can ask Cloudflare to
check a rule against the plan (see the note in step 1), so a rule your
plan does not allow shows up in `just cf-apply`, not in `just cf-plan`.

## Prerequisites

- The project devcontainer, which has `tofu` installed (pinned in
  `.devcontainer/Dockerfile`). Run every `cf-*` recipe there.
- A Cloudflare account with the zone, a remotely-managed tunnel and Zero
  Trust enabled, as set up by the other Cloudflare guides.

## 1. Create two API tokens

Plan and apply use separate tokens, and neither is stored in the repo.
Create both under **My Profile > API Tokens > Create Token > Create
Custom Token**, scoped to your account and to the cluster's zone only.

**Plan token (read-only)**: all of these with **Read**:

| Scope | Permission |
|-------|------------|
| Account | Access: Apps and Policies |
| Account | Access: Organizations, Identity Providers, and Groups |
| Account | Access: Service Tokens |
| Account | Cloudflare Tunnel |
| Zone | Zone |
| Zone | DNS |
| Zone | Zone Settings |
| Zone | Cache Rules |
| Zone | Zone WAF |

**Apply token (edit)**: the same list with **Edit** in place of
**Read**, except Zone: Zone, Access: Service Tokens and Access:
Organizations, Identity Providers, and Groups, which stay at Read (those
are only looked up). Give it a short expiry, or create it
when you need it and delete it afterwards: it can change your edge.

The plan token is read from `CF_PLAN_TOKEN`, else from
`cloudflare/.secrets/plan-token` (gitignored), else you are prompted.
The apply token is read from `CF_APPLY_TOKEN`, else you are prompted;
it is deliberately never read from a file.

:::{note}
For a ruleset it is about to create or change, the provider asks
Cloudflare to check it with a dry-run API call, which needs the edit
token. With the plan token, `just cf-plan` prints a warning, `failed to
make http request for the dry run` (403), and carries on; the check
runs again, with the edit token, when `just cf-apply` plans.
:::

```bash
mkdir -p -m 700 cloudflare/.secrets
read -rsp 'Plan token: ' t && printf '%s\n' "$t" > cloudflare/.secrets/plan-token && unset t
chmod 600 cloudflare/.secrets/plan-token
```

## 2. State and its encryption key

State is **local** (`cloudflare/terraform.tfstate`, gitignored) and
encrypted with OpenTofu's
[state encryption](https://opentofu.org/docs/language/state/encryption/)
(PBKDF2 key from a passphrase, AES-GCM). Saved plan files are encrypted
the same way. State holds the IDs and settings of everything managed,
including owner and viewer emails, which is why it is encrypted and kept
out of git.

The passphrase (16 characters or more) is read from
`TF_VAR_state_passphrase`, else from `cloudflare/.secrets/state-passphrase`
(gitignored), else you are prompted:

```bash
openssl rand -base64 24 > cloudflare/.secrets/state-passphrase
chmod 600 cloudflare/.secrets/state-passphrase
```

Keep a copy of the passphrase in your password manager. **Without it the
state cannot be read**; the encrypted state file itself is safe to copy
to a backup location such as the NAS.

If the state is lost, nothing at Cloudflare is affected: recreate it by
filling `import_ids` again and running a plan and apply, which imports
the objects afresh.

## 3. Fill in the account values

```bash
cp cloudflare/live.auto.tfvars.example cloudflare/live.auto.tfvars
```

Edit `cloudflare/live.auto.tfvars` (gitignored): account and zone IDs,
domain, team name, tunnel name, owner and viewer emails, any DNS-only
records, and the IDs of the existing
objects for the import blocks. Owner and viewer emails live here, not in
the code, because the repo is public.

The IDs come from the API (read-only calls with the plan token), for
example:

```bash
T=$(cat cloudflare/.secrets/plan-token); A=<account_id>; Z=<zone_id>
api() { curl -s -H "Authorization: Bearer $T" "https://api.cloudflare.com/client/v4/$1"; }
api "zones/$Z/dns_records?per_page=100" | jq -r '.result[] | "\(.name) \(.id)"'
api "accounts/$A/cfd_tunnel?is_deleted=false" | jq -r '.result[] | "\(.name) \(.id)"'
api "accounts/$A/access/apps" | jq -r '.result[] | "\(.name) \(.id)"'
api "accounts/$A/access/policies" | jq -r '.result[] | "\(.name) \(.id)"'
api "zones/$Z/rulesets" | jq -r '.result[] | select(.phase == "http_request_cache_settings") | .id'
```

The cache rule's `ref`, for `cache_rule_refs`, is in
`api "zones/$Z/rulesets/<ruleset_id>"` under `.result.rules[].ref`.

For a fresh account with none of these objects yet, leave `import_ids`
empty: the plan then creates everything.

## 4. First init and plan

```bash
just cf-init
just cf-plan
```

The first plan after filling `import_ids` must show only imports:

```
Plan: N to import, 0 to add, 0 to change, 0 to destroy.
```

Any `to add`, `to change` or `to destroy` means the code does not match
the live configuration: fix the code (or the values in
`live.auto.tfvars`) until it shows none. Then record the imports in
state:

```bash
just cf-apply
```

That apply only writes state (imports make no changes at Cloudflare), so
the read-only plan token is enough for it: give that at the prompt.
From then on `just cf-plan` should print `No changes. Your
infrastructure matches the configuration.` and the import blocks are
no-ops.

## Day to day

After a change of providers in `cloudflare/versions.tf` (such as the
`hashicorp/random` provider for the tunnel secret), run `just cf-init`
once to install it.

Run `just cf-plan`, `just cf-apply` and the other `cf-` recipes from
the main checkout, where the state and `live.auto.tfvars` are; a git
worktree has neither.

1. Change `cloudflare/` in a branch.
2. `just cf-plan` and check that the plan does what you meant.
3. Open the PR; CI runs `tofu fmt -check` and `tofu validate` (no
   credentials, no Cloudflare access).
4. After review, `just cf-apply` with the edit token, then merge.

Extra arguments pass through to `tofu`, for example
`just cf-plan -target=cloudflare_dns_record.tunnel`.

## Rotate the tunnel token

The tunnel's secret is 32 random bytes generated by the code
(`random_bytes.tunnel_secret` in `tunnel.tf`) and kept only in the
local, encrypted state, and the `tunnel_token` output is the token
`cloudflared` runs with. The state therefore holds a live credential:
keep it, and its passphrase, private. A new secret is an in-place update
of the tunnel: its ID, DNS records and public hostnames do not change.

Rotate only by changing `tunnel_secret_rotation`, never with **Rotate
token** in the dashboard. OpenTofu does not read the secret back from
Cloudflare, so after a dashboard rotation the state keeps the old,
dead secret and `just cf-seal-tunnel-token` would seal it.

Run every step from the main checkout of the repo, where the state and
`live.auto.tfvars` are, not from a git worktree. Do the whole procedure
in one go: from the apply onwards, the running `cloudflared` pods hold a
token that Cloudflare no longer accepts, and crash-loop the next time
they restart.

To rotate the token, for example after it has leaked:

1. In a branch, change `tunnel_secret_rotation` to any new value, either
   its default in `cloudflare/variables.tf` or by setting it in
   `cloudflare/live.auto.tfvars`.
2. `just cf-plan` should show `random_bytes.tunnel_secret` replaced and
   `cloudflare_zero_trust_tunnel_cloudflared.cluster` **updated in
   place**, never replaced.
3. `just cf-apply`. Cloudflare now refuses new connections that use the
   old token, but connections already up stay up until they are
   disconnected (step 7), including any connector someone else started
   with a leaked token.
4. `just cf-seal-tunnel-token`. It reads the token from the state (it
   asks for the state passphrase only, not an API token) and seals it into
   `kubernetes-services/additions/cloudflared/tunnel-secret.yaml` without
   printing it. If `.env` at the repo root (from
   `just export-external-creds`, for a rebuild) has a
   `CLOUDFLARE_TUNNEL_TOKEN` line, it updates that too, so a rebuild does
   not reseal the old token. The rebuild playbook reads
   `CLOUDFLARE_TUNNEL_TOKEN` from the environment, so source `.env` again
   (or open a new shell) before any rebuild.
5. Commit the SealedSecret (and the variable change), open the PR and
   merge it.
6. Wait for ArgoCD to sync it, then restart `cloudflared` so that it reads
   the new Secret:

   ```bash
   kubectl -n cloudflared rollout restart deployment/cloudflared
   kubectl -n cloudflared rollout status deployment/cloudflared
   ```

7. `just cf-tunnel-disconnect`. It asks for the edit token, lists the
   tunnel's connections, and after you confirm, disconnects every one of
   them. The cluster's pods reconnect within seconds with the new token,
   so expect a brief blip in public traffic; a connector that holds only
   the old token cannot reconnect.
8. Check the list it prints after reconnecting: every connector ID must be
   one of the cluster's pods (it prints their IDs from the pods' logs
   below the list), and every origin IP your own public address. Any
   other connector means something still holds a valid token: rotate
   again.

:::{note}
If the tunnel was adopted with an `import` block, it has no secret in
state, so the first `just cf-apply` after the secret came under this code
sets a new one. That apply is a rotation, whatever it was run for: do
steps 4 to 8 straight after it.
:::

## Later: state in an S3-compatible bucket

Local state suits a single operator. To share it, or to run `plan` in
CI, move it to an S3-compatible bucket (for example Backblaze B2) by
adding a backend to `cloudflare/versions.tf`:

```hcl
terraform {
  backend "s3" {
    bucket                      = "<bucket>"
    key                         = "cloudflare/terraform.tfstate"
    region                      = "<region>"
    endpoints                   = { s3 = "https://s3.<region>.backblazeb2.com" }
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
```

then, with the bucket's key in `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`:

```bash
cd cloudflare && tofu init -migrate-state
```

The state stays encrypted with the same passphrase, so the bucket only
ever holds ciphertext. This backend has no state locking unless you add
`use_lockfile = true`, which needs a bucket that supports conditional
writes; with one operator that is acceptable.

## Removing a service

Delete its entry from `tunnel_services` or `dns_only_records` (and any
Access app that only served it), and its ID from `import_ids` in
`live.auto.tfvars` (an import block for an object no longer in the
code is skipped; for DNS records a check also warns about the stale
key). Check that
`just cf-plan` destroys exactly those objects, and apply. Imported
configuration often carries such drift: entries for services the
cluster no longer runs, left behind by earlier dashboard edits.
