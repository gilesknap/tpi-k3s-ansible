# Accessing Services

How to connect to each cluster service via ingress or port-forward.
All services below assume you have completed the {doc}`bootstrap-cluster` steps.

:::{note}
The **ingress URLs** (`https://<service>.<domain>`) require DNS and TLS to be
configured first — see {doc}`cloudflare-tunnel` Parts 1–3. **Port-forward**
commands work immediately after bootstrap with no additional setup.
:::

## I want to…

| Task | Jump to |
|---|---|
| Watch ArgoCD sync status | [ArgoCD](#argocd) |
| Review ArgoCD app health history | [argocd-monitor](#argocd-monitor) |
| View cluster metrics and dashboards | [Grafana](#grafana) |
| Inspect pods, logs, and Kubernetes objects in a UI | [Headlamp (Kubernetes Dashboard)](#headlamp-kubernetes-dashboard) |
| Verify ingress, TLS and request headers end-to-end | [Echo Test Service](#echo-test-service) |
| Launch and manage Minecraft worlds | [Minecraft Dashboard](#minecraft-dashboard) |

## ArgoCD

Via ingress: **https://argocd.\<domain\>**

Via port-forward:

```bash
argo.sh
# Or manually:
kubectl port-forward svc/argocd-server -n argo-cd 8080:80
# Open http://localhost:8080
```

Click **Log in via GitHub** to authenticate through Dex. The built-in admin
account is disabled.

## argocd-monitor

Via ingress: **https://argocd-monitor.\<domain\>**

Authenticates via Dex (GitHub) using an oauth2-proxy sidecar. Click
**Sign in** to log in with your GitHub account. The dashboard inherits
your ArgoCD RBAC role (admin or readonly).

An Application's detail page links each workload, pod and node to the
matching [Grafana](#grafana) dashboard (CPU, memory, network, volumes),
with the workload's namespace already selected. The links open the
`kube-prometheus-stack` dashboards in this cluster's Grafana, set by the
`grafana` values in `kubernetes-services/templates/argocd-monitor.yaml`.
See the argocd-monitor
[observability links guide](https://epics-containers.github.io/argocd-monitor/main/how-to/observability-links.html)
for the full list of links and settings.

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
disabled. Emails in the `admin_emails` list get the Admin role; everyone
else gets Viewer. Grafana comes preconfigured with the
`kube-prometheus-stack` dashboards for cluster monitoring.

## Headlamp (Kubernetes Dashboard)

Via ingress: **https://headlamp.\<domain\>**

Via port-forward:

```bash
dashboard.sh   # port-forward on 4466 and print a 24h login token
# Or manually:
kubectl port-forward svc/headlamp -n headlamp 4466:80
# Open http://localhost:4466
```

Through the ingress, authenticate via GitHub (oauth2-proxy) first. Either way,
Headlamp then asks for a ServiceAccount token: `dashboard.sh` prints one, or
create one yourself:

```bash
kubectl create token headlamp -n headlamp --duration=24h
```

Paste the token into the login page to access the cluster dashboard.

## Minecraft Dashboard

Via ingress: **https://minecraft.\<domain\>** (only when `enable_minecraft`
is `true` — see {doc}`minecraft`)

Via port-forward:

```bash
kubectl port-forward svc/minecraft-dashboard -n minecraft 8080:80
# Open http://localhost:8080
```

Protected by oauth2-proxy — admin emails only. Players do not use this
page; they connect their Minecraft client to `mc.<domain>:<port>`, where the
port is shown in the dashboard.

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
