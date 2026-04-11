---
name: test-oauth-flow
description: Browser-test all cluster services for OAuth/auth flow verification. Delegates to a subagent to protect main context.
user-invocable: true
---

# Test OAuth Flow

Verify that every cluster service is reachable and authentication works
end-to-end using Chrome browser automation. This skill delegates all
browser work to a subagent to protect the main conversation context from
screenshot and redirect bloat.

## How to invoke

```
/test-oauth-flow
```

No arguments needed. Reads `cluster_domain` from `group_vars/all.yml`.

## Important rules

- **Delegate to a subagent** — launch a single `general-purpose` Agent
  with the full instructions below. Do not do browser work in the main
  conversation.
- **Chrome is NOT incognito** (CLAUDE.md) — sessions persist.
- **Never navigate to Google services** in the browser.
- **GitHub OAuth clicks are OK** — "Grant Access" on Dex and "Authorize"
  on GitHub only redirect back to the cluster.
- **Do NOT modify GitHub resources** in Chrome — no repo/issue/PR changes.
- **Stop on failure** — do not retry auth flows in a loop. Collect all
  failures and report them at the end.

## Subagent prompt

Pass the following to the subagent verbatim, with `<cluster_domain>`
replaced by the value from `group_vars/all.yml`:

---

### Browser OAuth Flow Verification

You are testing authentication flows for a K3s cluster. Use Chrome
browser automation tools (mcp__claude-in-chrome__*) throughout.

**Cluster domain**: `<cluster_domain>`

#### Step 1: Get browser context

Call `mcp__claude-in-chrome__tabs_context_mcp` to see current tabs.
Create a new tab with `mcp__claude-in-chrome__tabs_create_mcp`.

#### Step 2: Cookie clearing

Before testing each service, navigate to the URL and run this JavaScript
via `mcp__claude-in-chrome__javascript_tool` to clear stale cookies:

```javascript
document.cookie.split(';').forEach(c => {
  const name = c.split('=')[0].trim();
  document.cookie = name + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/';
  document.cookie = name + '=;expires=Thu, 01 Jan 1970 00:00:00 GMT;path=/;domain=.<cluster_domain>';
});
```

Then reload the page.

#### Step 3: Test services in order

**3a. Smoke tests (no auth):**

| Service | URL | Expected |
|---------|-----|----------|
| Echo | `https://echo.<cluster_domain>` | JSON echo response |
| ArgoCD | `https://argocd.<cluster_domain>` | Applications dashboard (already logged in) |

**3b. First Dex service (establishes GitHub session):**

| Service | URL | Action | Logged-in indicator |
|---------|-----|--------|---------------------|
| Grafana | `https://grafana.<cluster_domain>` | Click "Sign in with GitHub (via Dex)" | Page title "Home" or "Grafana" |

This is the slowest flow — Dex -> GitHub -> Grant Access -> redirect.
Subsequent Dex services reuse the session.

**3c. Remaining Dex services:**

| Service | URL | Action | Logged-in indicator |
|---------|-----|--------|---------------------|
| Open WebUI | `https://open-webui.<cluster_domain>` | See note about scroll-jacking below | Chat interface |
| ArgoCD Monitor | `https://argocd-monitor.<cluster_domain>` | Auto-redirects through sidecar oauth2-proxy -> Dex | HTML contains "argocd-monitor" |

**3d. oauth2-proxy services:**

| Service | URL | Logged-in indicator |
|---------|-----|---------------------|
| Headlamp | `https://headlamp.<cluster_domain>` | Token login page (after OAuth gate) |
| Longhorn | `https://longhorn.<cluster_domain>` | Page title "Longhorn" |
| Supabase | `https://supabase.<cluster_domain>` | Page title "Supabase" |

#### Step 4: OAuth flow procedure

For each service:
1. Navigate to the URL
2. Run cookie-clearing JavaScript from Step 2
3. Reload and wait up to 10 seconds for redirects
4. Handle redirects:
   - **Dex "Grant Access" page** -> click the submit button, wait 5s
   - **GitHub authorize page** -> click "Authorize" if visible, else wait 5s
   - **Service login page** -> click the OAuth/sign-in button
5. **Post-login validation** (CRITICAL — do this after every OAuth redirect):
   After the final redirect lands, run this JavaScript to detect errors:
   ```javascript
   JSON.stringify({
     url: window.location.href,
     title: document.title,
     // Check for common OAuth error patterns in visible text
     bodyText: document.body?.innerText?.substring(0, 2000) || '',
     // Specific error selectors
     hasLoginInUrl: window.location.pathname.includes('/login'),
     hasErrorInUrl: window.location.search.includes('error'),
   });
   ```
   Then check the result:
   - **FAIL if** the URL still contains `/login` AND the page text contains
     any of: "Login failed", "Failed to get token", "invalid_client",
     "access_denied", "unauthorized_client", "server_error", "temporarily_unavailable"
   - **FAIL if** the URL contains `error=` query parameter
   - **FAIL if** the page shows a raw error page (HTTP 500, 502, 503)
   - **PASS if** the page shows the expected logged-in content (dashboard,
     app interface, etc.) and the URL does NOT contain `/login`

   **Do NOT assume success just because the page loaded** — OAuth can
   redirect back to the login page with an error message that looks like
   a normal page at first glance.
6. Take a screenshot and record PASS or FAIL with evidence.
7. On FAIL, record the exact error text and URL. Do NOT retry in a loop.

#### Known gotchas

- **Open WebUI scroll-jacking** — the login page has a parallax animation.
  Use JavaScript to click the button:
  ```javascript
  document.querySelectorAll('button').forEach(b => {
    if (b.textContent.includes('GitHub')) b.click();
  });
  ```
- **Cloudflare Access redirect** — some services (currently Supabase)
  sit behind a Cloudflare Access app in addition to ingress oauth2-proxy.
  The non-incognito Chrome session usually has an existing
  `CF_Authorization` cookie that auto-approves. **But**: each Access app
  also sets a per-app `CF_AppSession` cookie with the `HttpOnly` flag.
  `document.cookie` cannot read or clear HttpOnly cookies, so the Step 2
  JS is useless against them. A stale `CF_AppSession` from a prior
  cluster session will make CF Access return **503 in the browser** even
  though the cluster-side path is healthy. To flush it, navigate to
  `https://<access-team>.cloudflareaccess.com/cdn-cgi/access/logout`
  before retrying. Note: the `clusterapps` Access policy requires
  interactive email-OTP sign-in with no SSO fallback — meaning after a
  logout, Supabase cannot be fully browser-tested automatically. Stop
  at the OTP prompt and report.
- **ArgoCD is usually already logged in** from the playbook run.
- **Post-redirect login page** — the most common false-positive is when
  OAuth completes the redirect but the service shows "Login failed" on
  its own login page. This looks like a successful page load but is
  actually a failure. Always check the page text for error messages
  after OAuth redirects.

#### Step 5: Report

Return a summary table:

```
| Service        | Status | Evidence                    |
|----------------|--------|-----------------------------|
| Echo           | PASS   | Echo response               |
| ArgoCD         | PASS   | Applications dashboard      |
| Grafana        | PASS   | Home page loaded            |
| Open WebUI     | PASS   | Chat interface              |
| ArgoCD Monitor | PASS   | Monitor page                |
| Headlamp       | PASS   | Token login page            |
| Longhorn       | PASS   | Dashboard loaded            |
| Supabase       | PASS   | Studio dashboard            |
```

Any FAIL entries must include:
- The final URL
- The exact error text visible on the page
- Whether the URL contained `/login` or `error=`

#### Step 6: Final state

Navigate to `https://argocd.<cluster_domain>/applications` so the user
sees the dashboard when done.

---

## Interpreting results

If services fail:

1. **"invalid client_secret"** — re-seal Dex with the matching subcommand
   (e.g. `just seal-argocd-dex grafana`), then `just restart-dex`.
2. **"Failed to get token from provider"** — the service-side secret
   doesn't match `argocd-dex-secret`. Re-seal all secrets.
3. **Redirect loop** — clear cookies and retry. If persistent, check
   oauth2-proxy cookie name conflicts.
4. **502/503** — diagnose cluster-side vs edge-side before touching pods:
   - `curl -o /dev/null -w '%{http_code}\n' https://<service>.<domain>` —
     a 302 to `*.cloudflareaccess.com` means the cluster-side path is fine.
   - `kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --since=5m | grep <service>` —
     only 401s mean oauth2-proxy is working as designed; 503s here mean a
     real origin problem. No 503s in ingress logs + a 503 in the browser =
     Cloudflare Access stale cookie (see gotcha above), not a pod issue.
   - Only after ruling those out: `kubectl get pods -A | grep -v Running`.
5. **Headlamp shows OIDC error** — the old OIDC config may still be cached.
   Restart the Headlamp pod: `kubectl rollout restart deployment headlamp -n headlamp`.
