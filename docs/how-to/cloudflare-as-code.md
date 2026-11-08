# Manage Cloudflare as Code (OpenTofu)

The cluster's edge configuration at Cloudflare (DNS records, the tunnel's
public hostnames, Zero Trust Access applications, policies and login
methods, zone security settings and cache rules) is described in
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
| `locals.tf` | `tunnel_services`: the list of public services. Each entry is a tunnel ingress rule (in list order, before the 404 catch-all) and a proxied CNAME to the tunnel; `cache = true` adds a cache rule for it |
| `tunnel.tf` | The remotely-managed tunnel and its ingress configuration |
| `dns.tf` | The tunnel CNAMEs, plus `dns_only_records` (records that bypass the tunnel) |
| `access.tf` | Login methods (one-time PIN, GitHub), reusable policies (Owner, Viewers, bypass, service token) and the Access applications |
| `zone.tf` | Zone settings (SSL mode, minimum TLS, HSTS, security level, ...) and the zone's cache rules |
| `imports.tf` | `import` blocks that adopt existing objects into state |
| `variables.tf` | Per-account inputs; the values go in the gitignored `live.auto.tfvars` |

Not managed: Cloudflare's managed rulesets (DDoS, the free managed WAF
ruleset), zone settings left at their defaults, and the Access service
token's lifecycle. The service token is looked up by name: its secret is
shown only once, when it is created, and has to be handed to the client,
so create or rotate it in the Zero Trust dashboard (**Access > Service
auth**). The tunnel's own secret is not managed either: `cloudflared`
runs with the tunnel token held in a SealedSecret. Nor are the zone's
(empty) custom WAF ruleset, the Zero Trust organization settings, and the
Access apps' `eager_redirect_cookie_setting`, which the provider's schema
does not have: check it in the dashboard after changing one of those apps.

To add a service to the edge, add an entry to `tunnel_services` (and, if
it needs something other than the wildcard Owner app, an entry in
`local.access_apps` in `access.tf`), then plan and apply.

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

**Apply token (edit)**: the same list with **Edit** in place of
**Read** (keep Zone: Zone at Read). Give it a short expiry, or create it
when you need it and delete it afterwards: it can change your edge.

The plan token is read from `CF_PLAN_TOKEN`, else from
`cloudflare/.secrets/plan-token` (gitignored), else you are prompted.
The apply token is read from `CF_APPLY_TOKEN`, else you are prompted;
it is deliberately never read from a file.

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
the same way. State holds the IDs of everything managed and can hold
secrets (for example the GitHub client secret after a rotation), which is
why it is encrypted and kept out of git.

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
domain, team name, tunnel name, owner and viewer emails, the GitHub
login's client ID, any DNS-only records, and the IDs of the existing
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
api "accounts/$A/access/identity_providers" | jq -r '.result[] | "\(.type) \(.id)"'
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

1. Change `cloudflare/` in a branch.
2. `just cf-plan` and check that the plan does what you meant.
3. Open the PR; CI runs `tofu fmt -check` and `tofu validate` (no
   credentials, no Cloudflare access).
4. After review, `just cf-apply` with the edit token, then merge.

Extra arguments pass through to `tofu`, for example
`just cf-plan -target=cloudflare_dns_record.tunnel`.

### The GitHub login's client secret

Cloudflare never returns an identity provider's client secret, so it is a
sensitive variable. An imported login method has no secret in state and
the variable is left unset (null), which leaves the live secret alone.

To rotate the secret, to change the GitHub login method, or on a fresh
account (where the first apply creates the login method), put the secret
in `cloudflare/.secrets/github-client-secret` (gitignored; `just cf-*`
reads it) and **keep it there**, backed up next to the state passphrase:
once applied, state holds the secret, and a plan without it would remove
it. If a plan shows `config.client_secret` changing when you did not mean
to rotate it, the file is missing (or you ran `tofu` directly rather than
through `just cf-*`): restore it, do not apply.

```bash
mkdir -p -m 700 cloudflare/.secrets
read -rsp 'GitHub client secret: ' s && printf '%s\n' "$s" > cloudflare/.secrets/github-client-secret && unset s
chmod 600 cloudflare/.secrets/github-client-secret
just cf-apply
```

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

## Next: removing drift

The first version of this code imports the live configuration exactly,
including entries for services the cluster no longer runs. Remove those
in a reviewed change: delete the entry from `tunnel_services` or
`dns_only_records` (and any Access app that only served it), check that
`just cf-plan` destroys exactly those objects, and apply.
