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

Prometheus stores metrics data on a static `local-nvme` PV on node04 (40Gi by
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

### Phone notifications (ntfy)

Alertmanager pushes the alerts worth acting on to the owner's phone through
the self-hosted ntfy ({doc}`ntfy`), on the `cluster-alerts` topic. Every
other alert goes to the `null` receiver: it still shows in Alertmanager and
Grafana, but nothing is sent. The configuration is the `alertmanager.config`
block in `kubernetes-services/templates/grafana.yaml`.

| Alerts | Pushed |
|--------|--------|
| Any `severity=critical` | yes, ntfy priority 5 (urgent) |
| `K3sEtcdBackup*` (the four etcd backup alerts) | yes, priority 3 |
| `KubeNodeNotReady` (fires after 15 minutes; not for a cordoned node) | yes, priority 3 |
| Volumes and filesystems filling up: `KubePersistentVolumeFillingUp`, `KubePersistentVolumeInodesFillingUp`, `NodeFilesystemSpaceFillingUp`, `NodeFilesystemAlmostOutOfSpace`, `NodeFilesystemFilesFillingUp`, `NodeFilesystemAlmostOutOfFiles` | yes, priority 3 (5 for their critical variants) |
| `CertManagerCertificateExpiringSoon` (under 14 days: warning; under 7: critical) | yes |
| `Watchdog`, `InfoInhibitor` and everything else | no (`null`) |

- **Grouping:** one notification per alert name (`group_by: [alertname]`),
  sent 2 minutes after the first alert of a group fires (`group_wait`), with
  changes to the group at most every 30 minutes (`group_interval`). A
  still-firing alert is pushed again once a day (`repeat_interval: 24h`).
- **Resolved:** when a group clears, a low-priority (2) "Resolved"
  notification follows.
- **Content:** ntfy formats Alertmanager's webhook JSON with its own
  `alertmanager-cluster` template
  (`kubernetes-services/additions/ntfy/files/alertmanager-cluster.yml`): the
  alert name in the title, then each alert's state, severity, node or
  namespace, summary and description, and a link to the alerts in
  Alertmanager. At most 5 alerts are listed (ntfy messages are limited to
  4 KB); the rest are counted.
- **Node down:** while a node is `KubeNodeNotReady`, its
  `KubeNodeUnreachable` and `KubeletInstanceUnreachable` are inhibited, and
  so are `KubePodNotReady`, `KubeDaemonSetRolloutStuck`,
  `KubeDaemonSetMisScheduled` and `TargetDown` cluster-wide (they carry no
  node label to match on). So a powered-off node is one push, not a dozen
  alerts.
- **Planned outages:** `KubeNodeNotReady` ignores cordoned nodes, so a node
  drained (which cordons it) before it is powered off pushes nothing. To
  power a node off without draining it, silence the alert first in the
  Alertmanager UI, or with:

  ```bash
  kubectl exec -n monitoring \
    alertmanager-grafana-prometheus-kube-pr-alertmanager-0 -c alertmanager -- \
    amtool --alertmanager.url=http://localhost:9093 silence add \
    node=<node> --duration=2h --comment="planned outage"
  ```

Alertmanager posts to the ntfy Service inside the cluster
(`http://ntfy.ntfy.svc.cluster.local`), not through Cloudflare; ntfy's
NetworkPolicy admits the Alertmanager pods for this (`allowed_pods` in
`kubernetes-services/additions/ntfy/values.yaml`). It authenticates as the
ntfy `alertmanager` user, which can only publish to `cluster-alerts`, with a
Bearer token read from the `alertmanager-ntfy` Secret (key `token`). That
Secret is a copy of the `alertmanager-token` key of `ntfy-auth`, as a pod can
only mount a Secret from its own namespace; `just seal-ntfy` and the rebuild
(`scripts/seal-from-json`) seal both together, so they stay in step.
Alertmanager reads the token file on every notification, so it needs no
restart for a rotated token (`just seal-ntfy --rotate alertmanager`). ntfy
accepts the new token only once its pod is recreated, and until then
publishes fail, so recreate the ntfy pod as soon as both Secrets have
synced (see {doc}`ntfy`).

:::{note}
Nothing pushes when the cluster, Alertmanager or ntfy itself is down. The
`Watchdog` alert, which always fires, is there to feed an external
dead-man's switch (such as healthchecks.io) that alerts when it *stops*
arriving; that is not set up here yet.
:::

### Test the notifications

To check delivery without waiting for a real problem, fire a short-lived
test alert with `amtool` inside the Alertmanager pod. It is critical, so it
is pushed with urgent priority after the 2 minute `group_wait`, and resolves
(with a "Resolved" push up to 30 minutes later) when it expires:

```bash
kubectl exec -n monitoring \
  alertmanager-grafana-prometheus-kube-pr-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 alert add \
  alertname=NtfyTestAlert severity=critical \
  '--annotation=summary="Test alert, please ignore"' \
  --start="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --end="$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
```

Give the start time explicitly: without it, Alertmanager starts the alert
at its end time, so it does not fire when you expect.

To see which receiver a set of labels would reach, without sending
anything:

```bash
kubectl exec -n monitoring \
  alertmanager-grafana-prometheus-kube-pr-alertmanager-0 -c alertmanager -- \
  amtool config routes test --config.file=/etc/alertmanager/config_out/alertmanager.env.yaml \
  alertname=KubeNodeNotReady severity=warning
```

If nothing arrives, check the Alertmanager logs (a rejected publish shows
the HTTP status) and the ntfy logs:

```bash
kubectl logs -n monitoring \
  alertmanager-grafana-prometheus-kube-pr-alertmanager-0 \
  -c alertmanager --tail=30
kubectl logs -n ntfy -l app.kubernetes.io/name=ntfy --tail=30
```
