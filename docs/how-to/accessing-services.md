# Accessing Services

How to connect to each cluster service via ingress or port-forward.
All services below assume you have completed the {doc}`bootstrap-cluster` steps.

:::{note}
The **ingress URLs** (`https://<service>.<domain>`) require DNS and TLS to be
configured first — see {doc}`cloudflare-tunnel` Parts 1–3. **Port-forward**
commands work immediately after bootstrap with no additional setup.
:::

## ArgoCD

Via ingress: **https://argocd.\<domain\>**

Via port-forward:

```bash
argo.sh
# Or manually:
kubectl port-forward svc/argocd-server -n argo-cd 8080:8080
# Open http://localhost:8080
```

Click **Log in via GitHub** to authenticate through Dex. The built-in admin
account is disabled.

## argocd-monitor

Via ingress: **https://argocd-monitor.\<domain\>**

Authenticates via Dex (GitHub) using an oauth2-proxy sidecar. Click
**Sign in** to log in with your GitHub account. The dashboard inherits
your ArgoCD RBAC role (admin or readonly).

## Grafana

Via ingress: **https://grafana.\<domain\>**

Via port-forward:

```bash
grafana.sh
# Or manually:
kubectl -n monitoring port-forward sts/grafana-prometheus 3000
# Open http://localhost:3000
```

Click **Sign in with GitHub (via Dex)** to log in. Password login is
disabled. Emails in the `oauth2_emails` list get the Admin role; everyone
else gets Viewer. Grafana comes preconfigured with the
`kube-prometheus-stack` dashboards for cluster monitoring.

## Longhorn UI

Via ingress: **https://longhorn.\<domain\>** (oauth2-proxy login)

Via port-forward:

```bash
longhorn.sh
```

Authenticate via GitHub (oauth2-proxy). The UI shows storage volumes,
replicas, and backup status.

## Headlamp (Kubernetes Dashboard)

Via ingress: **https://headlamp.\<domain\>**

Via port-forward:

```bash
dashboard.sh
# Or manually:
kubectl port-forward svc/headlamp -n headlamp 4466:80
# Open http://localhost:4466
```

Click **Sign in** to authenticate via Dex (GitHub). Admin emails get full
`cluster-admin` access; viewer emails get read-only `view` access.

## Open WebUI (LLM Chat)

Via ingress: **https://open-webui.\<domain\>**

Via port-forward:

```bash
kubectl port-forward svc/open-webui -n open-webui 8080:80
# Open http://localhost:8080
```

Click the OAuth button to log in via GitHub (through Dex). Password login is
disabled. Emails in the `oauth2_emails` list get admin access; others get the
user role. Models appear in the dropdown once pulled — see {doc}`rkllama-models`
or {doc}`llamacpp-models`.

:::{note}
RKLLama requires **RK1 compute modules** with the Rockchip NPU. llama.cpp requires
an **NVIDIA GPU** node. The services will deploy on any cluster but inference needs
the appropriate hardware.
:::

## Supabase Studio (Open Brain)

Supabase Studio is the admin UI for the Open Brain database — browse tables,
run SQL queries, and manage the `thoughts` schema.

:::{note}
Only available if you have enabled Open Brain — see {doc}`open-brain`.
:::

Via ingress: **https://supabase.\<domain\>** (behind oauth2-proxy)

Via port-forward:

```bash
kubectl port-forward svc/supabase-supabase-kong -n supabase 8000:8000
# Open http://localhost:8000
```

Two authentication steps: first authenticate via GitHub (oauth2-proxy),
then log in with the Supabase dashboard username and password generated
during {doc}`open-brain` setup. Use `just supabase-creds` to retrieve the
dashboard credentials.

## Echo Test Service

The echo service at **https://echo.\<domain\>** returns a JSON response with all
incoming request details — useful for verifying ingress, TLS, and headers.

:::{note}
Echo is intended as a public-facing test service exposed via the Cloudflare tunnel.
It is not included in local DNS — it becomes available after completing the
{doc}`cloudflare-tunnel` setup.
:::

:::{tip}
Install the [JSON Formatter](https://chromewebstore.google.com/detail/json-formatter/bcjindcccaagfpapjjmafapmmgkkhgoa)
Chrome extension to view the response pretty-printed in your browser.
:::
