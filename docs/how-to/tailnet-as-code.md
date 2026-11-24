# Manage the tailnet policy as code

The tailnet's policy file (who may reach what over Tailscale) is
[OpenTofu](https://opentofu.org) code in `tailscale/`, using the
[Tailscale provider](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs).
It works like {doc}`cloudflare-as-code`: a change is made in the repo and
reviewed like any other, then applied by the owner with
`just tailnet-apply`. Nothing in CI can change the tailnet. An edit made in
the admin console shows up as a change in the next `just tailnet-plan`, and
the next `just tailnet-apply` reverts it.

## What is in code

| File | What it holds |
|------|---------------|
| `tailscale/policy.hujson` | The whole policy file: host aliases, tag owners, grants and tests, with its comments |
| `tailscale/acl.tf` | One `tailscale_acl` resource that sends that file, and the `import` block that adopts the live policy |
| `tailscale/versions.tf` | The provider pin and the state encryption |
| `tailscale/live.auto.tfvars` | Gitignored: `owner_login`, the owner's Tailscale login |

The policy today:

- **The owner's own devices** reach everything: the tailnet, the VPS, and
  the home LAN through any subnet route. The grant names the owner's
  login, not `autogroup:member`, so anyone invited later starts with
  nothing. The repo is public, so `policy.hujson` holds a placeholder,
  `${owner_login}`, which OpenTofu fills in from `live.auto.tfvars`.
- **`tag:vps`** (the VPS) reaches only nuc2's tailnet IP on TCP 443, for
  scrap's `/mcp` ({ref}`scrap-canary`).
- **`tag:vps-relay`** (the `vps-relay` pod) reaches only frps on the VPS,
  TCP 7000 ({doc}`vps-relay`).
- **`tests`** assert those limits: the VPS cannot reach SSH or Jellyfin on
  nuc2, the relay or the LAN; the relay cannot reach SSH on the VPS or
  nuc2. Tailscale runs them when the plan validates the policy and again on
  apply, and refuses a policy that fails any.

### What is not code

- **The devices themselves**: joining a device to the tailnet, approving
  a subnet route, key expiry.
- **The tag on each device**: `tag:vps` is set on the VPS with
  `tailscale up --advertise-tags=tag:vps` or in the console
  (**Machines → ⋯ → Edit ACL tags**); the relay pod gets `tag:vps-relay`
  from its OAuth client ({doc}`vps-relay`, Step 2). The policy only defines
  who may own each tag.
- **OAuth clients**, including the two below.
- **Users and their roles**, and tailnet settings such as DNS.

## Set up the code against the tailnet

Once per checkout, in the devcontainer and in the main checkout (a git
worktree has neither the state nor `live.auto.tfvars`).

### 1. Create two OAuth clients

Plan and apply use separate OAuth clients, and neither is stored in the
repo. Create each in the admin console under **Settings → Trust
credentials → Credential → OAuth**, then **Generate credential**, and copy
the client ID and secret (the secret is shown only once). Tags do not apply
to these scopes; leave them empty.

| Client | Scopes |
|--------|--------|
| Plan (read-only) | **Policy File: Read**, and **Devices Core: Read** and **Posture Attributes: Read**, which Tailscale requires alongside it |
| Apply | **Policy File: Write**, and **Devices Core: Read** and **Posture Attributes: Write**, which Tailscale requires alongside it |

The read-only client can read and validate the policy but not change it.
It is read from `TS_PLAN_CLIENT_ID` and `TS_PLAN_CLIENT_SECRET`, else from
`tailscale/.secrets/plan-client-id` and `plan-client-secret` (gitignored),
else prompted for:

```bash
mkdir -p -m 700 tailscale/.secrets
read -rp 'Client ID: ' t && printf '%s\n' "$t" > tailscale/.secrets/plan-client-id
read -rsp 'Client secret: ' t && printf '%s\n' "$t" > tailscale/.secrets/plan-client-secret && unset t
chmod 600 tailscale/.secrets/*
```

The apply client can rewrite the whole policy, so its secret is not kept
anywhere: it is read from `TS_APPLY_CLIENT_ID` and `TS_APPLY_CLIENT_SECRET`,
else prompted for, never from a file. Keep it in the password manager.

### 2. State and the passphrase

State is local (`tailscale/terraform.tfstate`, gitignored) and encrypted
like the Cloudflare state, with **the same passphrase**: `just tailnet-*`
reads `TF_VAR_state_passphrase`, else
`cloudflare/.secrets/state-passphrase`, else prompts. Sharing it means one
passphrase to keep in the password manager for both
({doc}`cloudflare-as-code`, step 2, creates it).

Losing the state loses nothing at Tailscale: the next plan imports the live
policy again.

### 3. Fill in the owner's login

```bash
cp tailscale/live.auto.tfvars.example tailscale/live.auto.tfvars
```

Set `owner_login` to the owner's login, as the console's **Users** page
shows it.

### 4. First plan: adopt the live policy

```bash
just tailnet-init
just tailnet-plan
```

The first plan imports the live policy into state and compares it with
`policy.hujson`, showing the whole policy as a diff. It is the place to
check that the file matches what is live:

- `Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.` means the file
  matches the live policy exactly, comments included.
- `1 to import, 0 to add, 1 to change` shows the lines that differ. A
  difference only in comments or layout is harmless. A difference in a
  rule means the live policy has something the file does not (or the
  reverse): bring `policy.hujson` into line in a PR before the first apply,
  or the apply replaces the live rule.

Then apply with the write client:

```bash
just tailnet-apply
```

From then on `just tailnet-plan` prints `No changes.` and the import block
is a no-op.

## Day to day

1. Change `tailscale/policy.hujson` in a branch. Add or adjust a `tests`
   entry for any rule that limits a tag.
2. `just tailnet-plan` and check the diff. The plan also validates the
   policy with Tailscale and runs its tests, so a broken policy fails
   here.
3. Open the PR; CI runs `tofu fmt -check` and `tofu validate` (no
   credentials, no Tailscale access).
4. After review, `just tailnet-apply` with the write client, then merge.

`just tailnet-apply` shows the plan and asks for `yes` before it changes
anything. Claude sessions plan but never apply. Extra arguments pass
through to `tofu`.

## Troubleshooting

- **`Overwrite Protected`** on apply: the policy is not in state, so the
  provider refuses to replace it. The import block in `tailscale/acl.tf`
  normally prevents this; check it is still there and run
  `just tailnet-plan` again.
- **`Invalid ACL`** at plan: Tailscale rejected the policy, or one of its
  `tests` failed; the message names the test.
- **`401` or `403`**: the client ID or secret is wrong or revoked, or the
  client lacks the policy file scope (plan needs read, apply needs write).
