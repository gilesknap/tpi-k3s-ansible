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

**3d. Token auth:**

| Service | URL | Action | Logged-in indicator |
|---------|-----|--------|---------------------|
| Headlamp | `https://headlamp.<cluster_domain>` | Token login page loads (do NOT attempt to paste a token) | Login page visible with token input |

**3e. oauth2-proxy services:**

| Service | URL | Logged-in indicator |
|---------|-----|---------------------|
| Longhorn | `https://longhorn.<cluster_domain>` | Page title "Longhorn" |
| Supabase | `https://supabase.<cluster_domain>` | Page title "Supabase" |

#### Step 4: OAuth flow procedure

For each service:
1. Navigate to the URL
2. Run cookie-clearing JavaScript
3. Reload and wait up to 10 seconds for redirects
4. Check URL and page content:
   - **Dex "Grant Access" page** -> click the submit button, wait 5s
   - **GitHub authorize page** -> click "Authorize" if visible, else wait 5s
   - **Service login page** -> click the OAuth/sign-in button
   - **Authenticated page** -> take a screenshot, record PASS
5. On error, record FAIL with the error message. Do NOT retry.

#### Known gotchas

- **Open WebUI scroll-jacking** — the login page has a parallax animation.
  Use JavaScript to click the button:
  ```javascript
  document.querySelectorAll('button').forEach(b => {
    if (b.textContent.includes('GitHub')) b.click();
  });
  ```
- **Cloudflare Access redirect** — some services redirect through
  `*.cloudflareaccess.com` first. The browser's existing session
  typically auto-approves.
- **ArgoCD is usually already logged in** from the playbook run.

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

Any FAIL entries must include the error message or screenshot description.

#### Step 6: Final state

Navigate to `https://argocd.<cluster_domain>/applications` so the user
sees the dashboard when done.

---

## Interpreting results

If services fail:

1. **"invalid client_secret"** — run `just seal-argocd-dex` to re-seal
   Dex secrets, then `just restart-dex`.
2. **"Failed to get token from provider"** — the service-side secret
   doesn't match `argocd-dex-secret`. Re-seal all secrets.
3. **Redirect loop** — clear cookies and retry. If persistent, check
   oauth2-proxy cookie name conflicts.
4. **502/503** — pod not ready. Check `kubectl get pods -A | grep -v Running`.
5. **Headlamp shows OIDC error** — the old OIDC config may still be cached.
   Restart the Headlamp pod: `kubectl rollout restart deployment headlamp -n headlamp`.
