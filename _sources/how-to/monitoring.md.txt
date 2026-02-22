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

Additional services can be monitored by creating their own ServiceMonitor. For example,
Longhorn has `serviceMonitor.enabled: true` in its Helm values, which creates a
ServiceMonitor for Longhorn metrics.

## Data retention

Prometheus stores metrics data in a Longhorn persistent volume (40Gi by default,
configured in `kubernetes-services/templates/grafana.yaml`). Default retention is 10
days (kube-prometheus-stack default).

To change retention, add to the Prometheus Helm values:

```yaml
prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: 35GB
```

## Alerting

Alertmanager is deployed as part of the stack. By default, alerts are only visible
in the Alertmanager UI (accessible via port-forward):

```bash
kubectl -n monitoring port-forward svc/alertmanager-operated 9093
# Open http://localhost:9093
```

To configure alert notifications (email, Slack, PagerDuty), add an Alertmanager
config to the Helm values. See the
[kube-prometheus-stack documentation](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
for details.
