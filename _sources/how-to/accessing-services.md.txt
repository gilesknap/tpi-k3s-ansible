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
kubectl port-forward svc/argocd-server -n argo-cd 8080:443
# Open https://localhost:8080 (accept the self-signed certificate warning)
```

Login with `admin` and the shared admin password.

## Grafana

Via ingress: **https://grafana.\<domain\>**

Via port-forward:

```bash
grafana.sh
# Or manually:
kubectl -n monitoring port-forward sts/grafana-prometheus 3000
# Open http://localhost:3000
```

Login with `admin` and the shared admin password. Grafana comes preconfigured with
the `kube-prometheus-stack` dashboards for cluster monitoring.

## Longhorn UI

Via ingress: **https://longhorn.\<domain\>** (basic-auth prompt)

Via port-forward:

```bash
longhorn.sh
```

Login with `admin` and the shared admin password. The UI shows storage volumes,
replicas, and backup status.

## Headlamp (Kubernetes Dashboard)

Headlamp uses Kubernetes **token authentication** (not the shared admin password).

Generate a login token:

```bash
kubectl create token headlamp-admin -n headlamp --duration=24h
```

Via ingress: **https://headlamp.\<domain\>**

Via port-forward:

```bash
dashboard.sh
# Or manually:
kubectl port-forward svc/headlamp -n headlamp 4466:80
# Open http://localhost:4466
```

Paste the token into the login screen.

## Open WebUI (LLM Chat)

Via ingress: **https://open-webui.\<domain\>**

Via port-forward:

```bash
kubectl port-forward svc/open-webui -n open-webui 8080:80
# Open http://localhost:8080
```

First-time access requires creating an account — the first account registered
automatically becomes the admin. Models appear in the dropdown once pulled — see
{doc}`rkllama-models` or {doc}`llamacpp-models`.

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

Via ingress: **https://supabase.\<domain\>** (behind OAuth2 proxy)

Via port-forward:

```bash
kubectl port-forward svc/supabase-supabase-kong -n supabase 8000:8000
# Open http://localhost:8000
```

Login with the dashboard username and password you generated during
{doc}`open-brain` setup (default username: `admin`).

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
