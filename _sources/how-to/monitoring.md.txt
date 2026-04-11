# Monitoring with Grafana and Prometheus

This project deploys the [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
Helm chart, which includes Grafana, Prometheus, Alertmanager, and a suite of
pre-configured dashboards.

## Access Grafana

### Via ingress

**https://grafana.your-domain.com** — login with `admin` and the shared admin password
(set during {doc}`bootstrap-cluster`).

### Via port-forward

```bash
grafana.sh
# Or manually:
kubectl -n monitoring port-forward sts/grafana-prometheus 3000
# Open http://localhost:3000
```

## Default dashboards

The kube-prometheus-stack includes many dashboards out of the box:

| Dashboard | What it shows |
|-----------|---------------|
| Kubernetes / Compute Resources / Cluster | Cluster-wide CPU, memory, network |
| Kubernetes / Compute Resources / Namespace | Per-namespace resource usage |
| Kubernetes / Compute Resources / Pod | Per-pod CPU and memory |
| Node Exporter / Nodes | Node-level system metrics (CPU, memory, disk, network) |
| CoreDNS | DNS query rates and errors |
| etcd | etcd cluster health and performance |

Navigate to **Dashboards** in the Grafana sidebar to browse all available dashboards.

## How Prometheus scrapes metrics

Prometheus discovers scrape targets via **ServiceMonitor** resources. The
kube-prometheus-stack automatically creates ServiceMonitors for core Kubernetes
components.

Additional services can be monitored by creating their own ServiceMonitor — set
`serviceMonitor.enabled: true` in the service's Helm values (where supported) or
ship a ServiceMonitor manifest alongside the app.

## Data retention

Prometheus stores metrics data on a static `local-nvme` PV on node02 (40Gi by
default, configured in `kubernetes-services/templates/grafana.yaml`). Default
retention is 10 days (kube-prometheus-stack default).

To change retention, add to the Prometheus Helm values:

```yaml
prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: 35GB
```

## Alerting

Alertmanager is deployed as part of the stack and exposed at
**https://alertmanager.your-domain.com** behind the shared oauth2-proxy
(GitHub OAuth, admin emails only). The kube-prometheus-stack ships with a
suite of default alert rules covering node health, pod restarts, PVC usage,
certificate expiry, etc.

### Configure Slack notifications

Alertmanager is pre-configured to route all alerts to a `#alerts` Slack
channel via a webhook URL stored in the `alertmanager-slack-secret`
SealedSecret.

To populate the webhook:

1. **Create a Slack incoming webhook** at https://api.slack.com/apps:
   - Create New App → From scratch
   - Incoming Webhooks → toggle on → Add New Webhook to Workspace
   - Pick the `#alerts` channel and copy the webhook URL

2. **Seal it into the cluster**:

   ```bash
   kubectl create secret generic alertmanager-slack-secret \
     --namespace monitoring \
     --from-literal=webhook-url="https://hooks.slack.com/services/..." \
     --dry-run=client -o yaml | \
     kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml \
     > kubernetes-services/additions/grafana/alertmanager-slack-secret.yaml
   ```

3. **Commit and push** — ArgoCD syncs the SealedSecret, the controller
   decrypts it, and the Prometheus operator rolls the Alertmanager pod
   automatically with the webhook mounted.

### Test the Slack integration

Post a fake alert directly to the Alertmanager API:

```bash
kubectl exec -n monitoring \
  alertmanager-grafana-prometheus-kube-pr-alertmanager-0 \
  -c alertmanager -- \
  wget -qO- --post-data='[{"labels":{"alertname":"SlackTestAlert","severity":"warning"},"annotations":{"summary":"Test alert"}}]' \
  --header='Content-Type: application/json' \
  http://localhost:9093/api/v2/alerts
```

A message should appear in `#alerts` within 30 seconds (the configured
`group_wait`). If nothing arrives, check the alertmanager logs:

```bash
kubectl logs -n monitoring \
  alertmanager-grafana-prometheus-kube-pr-alertmanager-0 \
  -c alertmanager --tail=30
```
