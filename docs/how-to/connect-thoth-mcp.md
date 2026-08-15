# Connect Claude Code & Claude.ai to thoth over OAuth

This guide is the **client side** of {doc}`thoth`: once the MCP server is
deployed with OAuth 2.1 wired up, this is how you point Claude Code and
Claude.ai at it so thoth's `pkm_*` tools appear in your sessions.

thoth's `/mcp` endpoint speaks the
[MCP protocol](https://modelcontextprotocol.io/) (JSON-RPC over Streamable
HTTP) and authenticates each user with **OAuth 2.1 + PKCE**, using GitHub as
the identity provider. thoth is its own authorization server — there is no
separate login page and no API key to paste. You authorize once via GitHub
in a browser, the client stores the resulting token, and subsequent requests
carry it as `Authorization: Bearer <JWT>`.

## How the flow works

```
Claude Code / Claude.ai
  |  1. GET /.well-known/oauth-protected-resource   (discovery)
  |  2. dynamic client registration (RFC 7591)
  |  3. browser -> /authorize -> GitHub consent -> /callback
  |  4. /token  ->  JWT
  |  then: every /mcp call carries Authorization: Bearer <JWT>
  v
Cloudflare Edge (bypass Access app for thoth.<cluster_domain>)
  v
cloudflared -> ingress-nginx
  v
thoth MCP server  ->  Hindsight semantic index
```

The Cloudflare Access **bypass** application is what makes this work from
outside the LAN: the wildcard `*.<cluster_domain>` Access policy enforces
browser SSO, which a non-browser MCP client cannot solve. The bypass leaves
authentication entirely to thoth's own OAuth flow. Only GitHub usernames
listed in thoth's `allowedGithubUsers` config are admitted.

## Prerequisites

- thoth deployed with OAuth enabled — both `githubOauthClientId` and
  `oauthServerUrl` set, and the `thoth-env` Secret carrying
  `GITHUB_OAUTH_CLIENT_SECRET` + `THOTH_JWT_SIGNING_SECRET`. See
  {doc}`thoth` steps 1–4.
- A Cloudflare Tunnel route and an Access **bypass** application for
  `thoth.<cluster_domain>` that evaluates *before* the wildcard policy
  ({doc}`thoth` step 4, {doc}`cloudflare-web-tunnel`).
- Your GitHub username present in thoth's `allowedGithubUsers`.

## 1 -- Pre-flight: confirm OAuth discovery works

Before touching any client, prove the server advertises OAuth correctly from
**outside the LAN** (run this from your laptop on a different network, or a
phone hotspot — not from the devcontainer, which may reach the service by a
different path). Both metadata endpoints must return `200` with content type
`application/json`. This loop prints the status and content type for each,
and pretty-prints the body **only if it is JSON** — so an HTML login page
shows up as plain text instead of a cryptic `jq` parse error:

```bash
DOMAIN=thoth.<cluster_domain>
for ep in oauth-protected-resource oauth-authorization-server; do
  printf '\n== %s ==\n' "$ep"
  curl -sS "https://$DOMAIN/.well-known/$ep" \
       -o /tmp/thoth-disc -w 'HTTP %{http_code}  %{content_type}\n'
  jq . /tmp/thoth-disc 2>/dev/null || { echo '  (not JSON — first bytes:)'; head -c 200 /tmp/thoth-disc; echo; }
done
rm -f /tmp/thoth-disc
```

Pass condition: `HTTP 200  application/json` for both, and the
`oauth-protected-resource` document's `resource` field points at
`https://thoth.<cluster_domain>/mcp`.

If instead you get **`text/html`** (often with a `200` or `302` — it is the
Cloudflare Access login page) or a **`403`**, the request never reached
thoth's OAuth endpoint. Either the Access **bypass** application is missing
or ordered *after* the wildcard `*.<cluster_domain>` policy, or thoth is not
deployed (so the hostname falls through to a 404/Access page). Fix that
first ({doc}`thoth` step 4) — every client below depends on these two
endpoints returning JSON.

## 2 -- Connect Claude Code

Register the server once with the HTTP transport:

```bash
claude mcp add --transport http thoth https://thoth.<cluster_domain>/mcp
```

The first time a Claude Code session connects, it opens a browser for the
GitHub OAuth consent screen. Approve it (with a GitHub account that is in
`allowedGithubUsers`) and the token is cached for future sessions. Then:

```
/mcp
```

in a session lists thoth's `pkm_*` tools. If you ever need to re-authorize
(for example after rotating the JWT signing secret), remove and re-add:

```bash
claude mcp remove thoth
claude mcp add --transport http thoth https://thoth.<cluster_domain>/mcp
```

:::{note}
The devcontainer in this repo runs Claude Code inside a bwrap sandbox with no
browser. Register and authorize thoth from a Claude Code instance running on
your **host** (or any machine with a browser), not from inside the
devcontainer. See {doc}`claude-code`.
:::

## 3 -- Connect Claude.ai

1. Open [claude.ai](https://claude.ai/) and go to a **Project** (or create
   one).
2. Open **Project settings > Integrations** (or **Connectors**, depending on
   the current UI).
3. Click **Add integration** / **Add custom integration**.
4. Enter the **URL**: `https://thoth.<cluster_domain>/mcp`

Claude.ai initiates the OAuth flow automatically — you are redirected to
GitHub to authorize. No API key or custom header is needed. After consent,
thoth's `pkm_*` tools appear in the project's tool list.

## 4 -- Verify

In a fresh conversation (a Project conversation in Claude.ai, or any Claude
Code session):

1. Ask Claude to list its available tools — the `pkm_*` tools should appear.
2. Ask it to run a read-only `pkm_*` tool (e.g. a search/stats tool) and
   confirm it returns a result rather than an auth error.
3. Capture something and confirm it lands in your PKM vault repo.

## Troubleshooting

### Discovery endpoint returns an HTML login page or 403

The Cloudflare Access bypass for `thoth.<cluster_domain>` is missing or is
ordered *after* the wildcard `*.<cluster_domain>` policy, so the wildcard
intercepts the request. Add the bypass application and confirm its order in
the Zero Trust dashboard ({doc}`thoth` step 4).

### Browser never opens / OAuth consent loops

- Confirm the GitHub OAuth App's **Authorization callback URL** is exactly
  `https://thoth.<cluster_domain>/callback` (no trailing slash).
- Check the MCP server logs for OAuth errors:
  `kubectl logs -n thoth deploy/thoth-mcp`.
- Verify `githubOauthClientId` / `oauthServerUrl` in
  `kubernetes-services/templates/thoth.yaml` and the sealed
  `GITHUB_OAUTH_CLIENT_SECRET` match the GitHub OAuth App.

### "403 / not authorized" after a successful GitHub consent

OAuth succeeded but your GitHub username is not in thoth's
`allowedGithubUsers`. Add it to the `config.allowedGithubUsers`
comma-separated list in `kubernetes-services/templates/thoth.yaml`, commit,
push, and let ArgoCD sync.

### Tools vanished after a thoth restart

thoth registers MCP clients dynamically (RFC 7591) and keeps client state
**in memory**, so a pod restart invalidates previously issued tokens.
Clients normally re-register transparently on their next connect; if not,
remove and re-add the connector (Claude Code) or disconnect/reconnect the
integration (Claude.ai) to trigger a fresh OAuth flow.

### "Unauthorized" / 401 on tool calls

The JWT has likely expired. Disconnect and reconnect (Claude.ai) or
`claude mcp remove thoth` then re-add (Claude Code) to mint a fresh token.

## Falling back to the bearer token

OAuth is the path for interactive MCP clients. For in-cluster scripts, the
reindex job, and `curl` smoke tests, thoth also accepts a shared bearer key
(`THOTH_MCP_API_KEYS`) in **dual mode** alongside OAuth — see the bearer-token
smoke test in {doc}`thoth` step 5. Interactive clients (Claude Code,
Claude.ai) should always use OAuth, not the shared key.

## See also

- {doc}`thoth` — Deploy the thoth MCP server and wire up OAuth (server side)
- {doc}`cloudflare-web-tunnel` — Expose services and configure Access bypass
- {doc}`claude-code` — Using Claude Code in this repo
- [MCP Protocol specification](https://modelcontextprotocol.io/)
