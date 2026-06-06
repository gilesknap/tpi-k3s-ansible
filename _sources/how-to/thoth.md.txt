# thoth (Slack PKM + Hindsight)

[thoth](https://github.com/gilesknap/thoth) is an optional Slack capture
daemon plus an HTTP [MCP](https://modelcontextprotocol.io/) server backed by
a networked [Hindsight](https://github.com/vectorize-io/hindsight) semantic
index. The cluster deploys it from the **OCI Helm chart** published by the
thoth repo's CI; this overlay only ships the cluster-specific
{doc}`SealedSecret <manage-sealed-secrets>` and the ArgoCD `Application`.

The MCP server authenticates in two parallel modes:

- **Bearer token** (`THOTH_MCP_API_KEYS`) — a shared secret for in-cluster
  scripts, the reindex job, and curl smoke tests.
- **OAuth 2.1 + PKCE** — per-user GitHub identity, so external MCP clients
  (claude.ai, Claude Code) can connect from outside the LAN. thoth acts as
  its own authorization server; the cluster only has to stop Cloudflare
  Access from challenging non-browser clients (see the prerequisites and
  step 4).

:::{note}
The chart is amd64-only (defaults to `nodeSelector: kubernetes.io/arch: amd64`)
because the published image is single-arch. The embedded Hindsight Postgres
data lives on a `ReadWriteOnce` `local-path` PVC, so the pod sticks to
whichever amd64 node it first schedules on. Cordon or taint the other amd64
nodes if you want to pin it explicitly.
:::

## Prerequisites

- An x86/amd64 node in your cluster
- A Slack app with bot + app-level (socket-mode) tokens
- An [Anthropic API key](https://console.anthropic.com/) (used by both the
  MCP server and Hindsight for fact extraction)
- A [Firecrawl](https://firecrawl.dev/) API key (URL ingestion)
- A GitHub fine-grained PAT with `contents:write` on your PKM vault repo
- [Cloudflare Tunnel](cloudflare-web-tunnel) (or any way to reach the
  in-cluster ingress) if you want the MCP endpoint from outside
- **A GitHub OAuth App for thoth** (for OAuth 2.1 logins). Create one at
  <https://github.com/settings/developers> with:
  - Homepage URL: `https://thoth.<cluster_domain>`
  - Authorization callback URL: `https://thoth.<cluster_domain>/callback`

  Capture the client ID and client secret — they go into the sealed Secret
  in step 2.
- **A Cloudflare Access *bypass* application for `thoth.<cluster_domain>`**.
  The wildcard `*.<cluster_domain>` Access policy enforces browser SSO,
  which non-browser MCP clients cannot solve. A bypass application that
  evaluates *before* the wildcard leaves authentication entirely to thoth's
  own OAuth flow. See {doc}`cloudflare-web-tunnel` and step 4 below.

## 1 -- Enable thoth in values.yaml

Edit `kubernetes-services/values.yaml`:

```yaml
enable_thoth: true
thoth:
  chart_version: "0.8.0-beta.1"
  image_tag: "0.8.0-beta.1"
```

Bump both versions in lockstep when a new tag is published to
`oci://ghcr.io/gilesknap/charts/thoth`.

### OAuth config in the ArgoCD Application

The chart splits OAuth configuration in two: the *non-secret* parameters are
plain chart `config.*` values (they end up in the ConfigMap), and only the two
genuinely sensitive values live in the sealed Secret (step 2). Set the
non-secret config in this repo's `kubernetes-services/templates/thoth.yaml`
(the thoth `Application`'s `valuesObject`), alongside the existing
`mcpAllowedHosts`/`mcpAllowedOrigins`:

```yaml
          config:
            mcpAllowedHosts: "thoth.{{ .Values.cluster_domain }}"
            mcpAllowedOrigins: "https://thoth.{{ .Values.cluster_domain }}"
            # MCP OAuth 2.1 (non-secret config). The client SECRET and JWT
            # signing secret live in the sealed thoth-env Secret (step 2).
            githubOauthClientId: "<GitHub OAuth App client ID>"
            oauthServerUrl: "https://thoth.{{ .Values.cluster_domain }}"
            allowedGithubUsers: "gilesknap"   # comma-separated GitHub usernames
```

The GitHub OAuth App **client ID** is not a secret (it travels in the public
authorize URL), so it lives here in the committed `valuesObject`, not in the
Secret. OAuth stays off — only the `THOTH_MCP_API_KEYS` bearer path is
accepted — until both `githubOauthClientId` and `oauthServerUrl` are set, so
these keys can be committed empty and filled once the OAuth App exists.

## 2 -- Seal the thoth-env secret

The upstream chart expects a pre-existing Secret named `thoth-env` in the
`thoth` namespace, carrying the API keys plus — for OAuth — two secret
values: `GITHUB_OAUTH_CLIENT_SECRET` and `THOTH_JWT_SIGNING_SECRET`. (The
*non-secret* OAuth config — client ID, server URL, allowed users — lives in
the chart `valuesObject`, see step 1, not here.)

How you seal depends on whether `thoth-env` already exists.

### Adding the OAuth keys to an existing thoth-env (recommended)

If thoth is already deployed — the usual case when turning OAuth on — you do
**not** need to re-enter the other nine values. Seal only the two new keys
and merge them into the committed file with `kubeseal --merge-into`, which
leaves the existing encrypted entries untouched:

```bash
read -rsp 'GitHub OAuth App client secret: ' GITHUB_OAUTH_CLIENT_SECRET; echo
JWT_SIGNING_SECRET="$(openssl rand -hex 32)"

kubectl create secret generic thoth-env \
  --namespace thoth \
  --from-literal=GITHUB_OAUTH_CLIENT_SECRET="$GITHUB_OAUTH_CLIENT_SECRET" \
  --from-literal=THOTH_JWT_SIGNING_SECRET="$JWT_SIGNING_SECRET" \
  --dry-run=client -o yaml \
| kubeseal --controller-name sealed-secrets \
           --controller-namespace kube-system \
           --format yaml \
           --merge-into kubernetes-services/additions/thoth/templates/thoth-secret.yaml

unset GITHUB_OAUTH_CLIENT_SECRET JWT_SIGNING_SECRET
```

`--merge-into` works because the mini-Secret's name/namespace
(`thoth-env` / `thoth`) match the existing SealedSecret's strict scope —
this is the kubeseal-native equivalent of the per-secret `seal-argocd-dex`
subcommands. Both sealed values are real (the prompted secret and the
generated key), so you sidestep the placeholder-base64 foot-gun in
{doc}`manage-sealed-secrets`. Skip ahead to the pod-restart note below.

### Sealing thoth-env from scratch (fresh install)

If `thoth-env` does not exist yet, build the full plaintext Secret and seal
it in one shot. Prompt for the OAuth client secret and generate the random
keys so they never have to be typed into the file by hand:

```bash
read -rsp 'GitHub OAuth App client secret: ' GITHUB_OAUTH_CLIENT_SECRET; echo
JWT_SIGNING_SECRET="$(openssl rand -hex 32)"
THOTH_MCP_API_KEY="$(openssl rand -hex 32)"

(umask 077; cat > /tmp/thoth-env.secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: thoth-env
  namespace: thoth
type: Opaque
stringData:
  # --- core / Slack / Hindsight (edit the placeholders below) ---
  ANTHROPIC_API_KEY: "sk-ant-..."
  FIRECRAWL_API_KEY: "fc-..."
  GITHUB_PKM_VAULT_TOKEN: "github_pat_..."
  SLACK_BOT_TOKEN: "xoxb-..."
  SLACK_APP_TOKEN: "xapp-..."
  SLACK_ALLOWED_USERS: "U0123ABC"      # comma-separated Slack user IDs
  SLACK_CAPTURE_CHANNEL: "C0123ABC"    # channel ID, not name
  SLACK_SUMMARY_CHANNEL: "C0123ABC"
  # --- bearer-token auth (dual-mode; keep this working) ---
  THOTH_MCP_API_KEYS: "${THOTH_MCP_API_KEY}"
  # --- OAuth 2.1 secrets only. The non-secret OAuth config (client ID,
  #     server URL, allowed users) lives in the chart valuesObject, not here
  #     (see "OAuth config in the ArgoCD Application" under step 1). ---
  GITHUB_OAUTH_CLIENT_SECRET: "${GITHUB_OAUTH_CLIENT_SECRET}"
  THOTH_JWT_SIGNING_SECRET: "${JWT_SIGNING_SECRET}"
EOF
)
```

The `umask 077` keeps the file `600` from the moment it is created, before
any real tokens land in it.

Now open `/tmp/thoth-env.secret.yaml` in your editor and replace every
`"..."` placeholder in the core/Slack/Hindsight block with the real value
(the bearer key and the two OAuth/JWT keys are already filled in from the
prompt and `openssl` above). **Do not seal the file with placeholders
still in it** — `kubeseal` happily encrypts them and thoth then comes up
with garbage credentials and runtime errors that do not obviously point
back here.

Once the values are real, seal the manifest and delete the plaintext:

```bash
kubeseal --controller-name sealed-secrets \
         --controller-namespace kube-system \
         --format yaml \
  < /tmp/thoth-env.secret.yaml \
  > kubernetes-services/additions/thoth/templates/thoth-secret.yaml \
  && rm -f /tmp/thoth-env.secret.yaml
```

If `kubeseal` fails (controller unreachable, wrong context, …) the `&&`
short-circuits and leaves the plaintext file behind — delete it manually
with `rm -f /tmp/thoth-env.secret.yaml` before retrying.

The sealed file **must** stay named `thoth-secret.yaml` (singular) — the
`*-secrets.yaml` plural is blocked by gitleaks. See
{doc}`manage-sealed-secrets`.

The Hindsight pod reuses `ANTHROPIC_API_KEY` from the same Secret for its
fact-extraction LLM. The two OAuth secret keys are additive — the bearer-token
path via `THOTH_MCP_API_KEYS` keeps working alongside OAuth.

:::{note}
Pods cache `secretKeyRef`/`envFrom` values at startup, so after the resealed
Secret syncs you must restart the thoth pods to pick up the new keys:

```bash
kubectl rollout restart deployment -n thoth
```
:::

## 3 -- Commit and deploy

```bash
git add kubernetes-services/values.yaml \
        kubernetes-services/templates/thoth.yaml \
        kubernetes-services/additions/thoth/
git commit -m "Enable thoth via published OCI Helm chart"
git push
```

Then deploy via the playbook:

```bash
ansible-playbook pb_all.yml --tags cluster
```

ArgoCD creates the `thoth` Application and pulls the chart from
`oci://ghcr.io/gilesknap/charts`. Watch progress:

```bash
kubectl get app thoth -n argo-cd -w
kubectl get pods -n thoth -w
```

All thoth pods (Slack daemon, MCP server, Hindsight) should reach
`Running` on the pinned node within a few minutes.

## 4 -- Wire Cloudflare for external OAuth

Cloudflare Access configuration is **not** in-repo — these are manual
changes in the Cloudflare dashboards (see {doc}`cloudflare-web-tunnel` for
which dashboard is which). Two changes make "connect from anywhere" work:

- **Tunnel hostname route.** Ensure `thoth.<cluster_domain>` routes through
  `cloudflared` to
  `http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local`.
  Never point the tunnel directly at a Service — that bypasses ingress-nginx
  and breaks ingress-level features.
- **Cloudflare Access bypass policy.** Add a bypass application for
  `thoth.<cluster_domain>` so it is exempt from the wildcard
  `*.<cluster_domain>` browser-SSO policy. Non-browser MCP clients cannot
  solve that SSO challenge; the bypass leaves authentication entirely to
  thoth's own OAuth flow. The bypass application **must evaluate before**
  the wildcard policy — confirm the policy order in the Zero Trust
  dashboard, otherwise the wildcard still intercepts requests.

Once the bypass is in place, flip DNS for `thoth.<cluster_domain>` to
proxied (orange-cloud).

## 5 -- Smoke test

- Send a message in your `SLACK_CAPTURE_CHANNEL` and confirm thoth files a
  page in the PKM vault repo.
- **OAuth discovery** — from a host outside the LAN, both metadata
  endpoints should return `200` JSON (this proves the Cloudflare Access
  bypass and tunnel route are correct):

  ```bash
  curl -s https://thoth.<cluster_domain>/.well-known/oauth-protected-resource | jq .
  curl -s https://thoth.<cluster_domain>/.well-known/oauth-authorization-server | jq .
  ```

- **Bearer token (legacy / dual-mode)** — the shared key still works.
  `/mcp` is the MCP Streamable HTTP endpoint, so POST a JSON-RPC request
  rather than a bare `GET`; a `200` with a JSON-RPC result (not a `401`) is
  the pass condition:

  ```bash
  KEY=$(kubectl get secret -n thoth thoth-env \
        -o jsonpath='{.data.THOTH_MCP_API_KEYS}' | base64 -d)
  curl -s -X POST https://thoth.<cluster_domain>/mcp \
       -H "Authorization: Bearer $KEY" \
       -H 'Content-Type: application/json' \
       -H 'Accept: application/json, text/event-stream' \
       -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
  ```

  (The decoded key is passed on the command line, so it is briefly visible
  in your shell history and the process list — run this on a host you
  trust.)

- Trigger the manual reindex:

  ```bash
  kubectl -n thoth create job --from=cronjob/thoth-reindex manual-reindex
  ```

## Connect Claude.ai / Claude Code

With OAuth wired up, MCP clients authenticate per-user via GitHub (only
usernames in `THOTH_ALLOWED_GITHUB_USERS` are admitted) and thoth's `pkm_*`
tools become available.

**claude.ai** — open your Project, go to **Integrations**, add a custom
integration with URL `https://thoth.<cluster_domain>/mcp`, then complete the
GitHub consent prompt. thoth's `pkm_*` tools appear in the tool list.

**Claude Code** — register the server once:

```bash
claude mcp add --transport http thoth https://thoth.<cluster_domain>/mcp
```

The first connection opens a browser for the GitHub OAuth flow; afterwards
`/mcp` in a Claude Code session lists thoth's `pkm_*` tools.

:::{note}
thoth registers MCP clients dynamically (RFC 7591) and keeps the client
state in memory, so a pod restart silently invalidates previously issued
tokens. Clients re-register transparently on their next connect — you will
not normally notice.
:::

## Disable thoth

Set `enable_thoth: false` in `kubernetes-services/values.yaml`, commit,
push, and re-run the playbook. ArgoCD will prune the Application. The
embedded Hindsight Postgres data lives on a `local-path` PVC that is
**not** preserved across cluster rebuilds — back up the bank first if you
need it.
