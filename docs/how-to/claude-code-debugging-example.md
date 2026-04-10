# Worked Example: Debugging Cluster Alerts with Claude Code

This is a real (lightly edited) transcript of a session in which Claude
Code diagnosed a set of Prometheus alerts firing on the cluster, proposed
a fix, opened a pull request, and validated the change against the live
cluster — all driven from short natural-language prompts.

It is intended as a practical example of what "AI-assisted operations"
looks like on a homelab K3s cluster: Claude does the read-only kubectl
spelunking and writes the patch; the human stays in the loop for the
judgement calls and the merge.

## Setting

The cluster is the GitOps-managed K3s setup described in
[Architecture](../explanations/architecture.md). Alertmanager delivers
firing alerts to a Slack channel. One afternoon the user notices four
alerts have fired and asks Claude to take a look.

## Transcript

### 1. Reporting the symptom

> **User:**
> we had some alerts. diagnose: gkcluster alerts
>
> ```
> APP  3:59 PM
> [FIRING:1] TargetDown monitoring
>     (grafana-prometheus-kube-pr-operator
>      monitoring/grafana-prometheus-kube-pr-prometheus
>      grafana-prometheus-kube-pr-operator warning)
>      4:04
> [FIRING:1] KubeSchedulerDown
>     (kube-scheduler monitoring/grafana-prometheus-kube-pr-prometheus critical)
>      4:04
> [FIRING:1] KubeProxyDown
>     (kube-proxy monitoring/grafana-prometheus-kube-pr-prometheus critical)
>      4:04
> [FIRING:1] KubeControllerManagerDown
>     (kube-controller-manager monitoring/grafana-prometheus-kube-pr-prometheus critical)
> ```

### 2. Investigation

Claude started with the obvious health checks — all read-only:

```bash
kubectl get nodes -o wide
kubectl -n monitoring get pods
```

Both came back clean: 6 nodes Ready, every monitoring pod Running. So
the alerts weren't reflecting actual workload failure — they were
*scrape-config* failures. Claude then queried Prometheus's own targets
API from inside the pod:

```bash
kubectl -n monitoring exec prometheus-grafana-prometheus-kube-pr-prometheus-0 \
  -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active'
```

Two findings emerged from grouping the results by job:

| Job | Up | Down | Notes |
|---|---|---|---|
| `grafana-prometheus-kube-pr-operator` | 0 | 1 | TLS verify error |
| `kube-scheduler` / `kube-proxy` / `kube-controller-manager` | — | — | No targets discovered at all |
| everything else | ✓ | 0 | Healthy |

The down operator target was reporting:

```
tls: failed to verify certificate: x509: certificate is valid for
grafana-prometheus-kube-pr-admission.monitoring.svc, ...,
not grafana-prometheus-kube-pr-operator
```

The K3s control-plane Services had **empty endpoints**:

```bash
kubectl -n kube-system get svc | grep -E 'scheduler|proxy|controller'
# grafana-prometheus-kube-pr-kube-controller-manager  ClusterIP  None  10257/TCP
# grafana-prometheus-kube-pr-kube-proxy               ClusterIP  None  10249/TCP
# grafana-prometheus-kube-pr-kube-scheduler           ClusterIP  None  10259/TCP
```

No pods carry the `component: kube-scheduler` label that those Services
select on, so the absent-style `Kube*Down` rules fire on every evaluation.

### 3. Diagnosis

Claude reported back with two distinct root causes:

**Cause 1 — operator `TargetDown`.** The kube-prometheus-stack operator
serves its metrics endpoint over TLS using the cert from the
`grafana-prometheus-kube-pr-admission` Secret. That secret is created on
fresh installs by `scripts/create-prometheus-admission-secret`, which
generated a single-CN certificate with **no Subject Alternative Name
list**. Modern TLS verification ignores CN entirely and requires a SAN
match — so the ServiceMonitor's `serverName: grafana-prometheus-kube-pr-operator`
could never match. Failing every scrape.

**Cause 2 — `KubeScheduler/Proxy/ControllerManagerDown`.** K3s bundles
those three components into the single `k3s-server` process. There are
no individual pods with `component=kube-scheduler` etc., so the
chart-default Services have empty endpoints, the `up{}` series is
absent, and the matching default rules fire.

The two are independent. The cluster itself was completely healthy —
this was monitoring config drift, not workload failure.

### 4. Reframing the fix

Claude's first instinct on Cause 1 was to suggest disabling TLS on the
operator (`prometheusOperator.tls.enabled: false`) since the cluster is
single-tenant. The user pushed back:

> **User:**
> isn't prometheus operator tls usually enabled? this is removing a security feature, right?

Good question, and the honest answer is yes — the chart ships with
`prometheusOperator.tls.enabled: true` by default, the same cert is
reused if the admission webhook is ever re-enabled, and it costs almost
nothing to keep. The real bug isn't TLS — it's that our cert generator
forgot the SAN list.

Claude revised the proposal: keep TLS on, fix the cert generator
instead. One `-addext` line on the `openssl req` command, with SAN
entries for all six forms the ServiceMonitor or peer DNS lookups might
expect:

- `grafana-prometheus-kube-pr-admission` (bare)
- `grafana-prometheus-kube-pr-admission.monitoring.svc`
- `grafana-prometheus-kube-pr-admission.monitoring.svc.cluster.local`
- `grafana-prometheus-kube-pr-operator` (bare — this is the literal `serverName`)
- `grafana-prometheus-kube-pr-operator.monitoring.svc`
- `grafana-prometheus-kube-pr-operator.monitoring.svc.cluster.local`

For Cause 2, the cleanest fix is to disable the K3s-incompatible
exporters and their default rules in the Helm values; the same metrics
remain visible via the kubelet and apiserver ServiceMonitors.

### 5. Implementing the fix

Claude branched from `origin/main` and made three edits, all flowing
through ArgoCD via the GitOps pipeline (no direct cluster mutations):

1. **`scripts/create-prometheus-admission-secret`** — added the
   `subjectAltName` extension to the `openssl req` invocation.

2. **`kubernetes-services/templates/grafana.yaml`** — added the K3s
   component disables to the `valuesObject` of the
   `kube-prometheus-stack` Helm release:

   ```yaml
   kubeControllerManager:
     enabled: false
   kubeScheduler:
     enabled: false
   kubeProxy:
     enabled: false
   defaultRules:
     rules:
       kubeControllerManager: false
       kubeScheduler: false
       kubeProxyAlerting: false
   ```

3. **`roles/cluster/tasks/main.yml`** — Claude noticed the Ansible task
   inlined its own copy of the cert-generation logic instead of calling
   the script, which would have silently re-minted the buggy cert on
   the next playbook run. Replaced the inline `shell` task with a
   `command` invocation of the script, so there is one source of truth.

Each cert SAN list was sanity-checked locally before committing:

```bash
openssl x509 -in /tmp/c.pem -noout -ext subjectAltName
# X509v3 Subject Alternative Name:
#   DNS:grafana-prometheus-kube-pr-admission, DNS:...operator, ...
```

### 6. Open the PR and test

> **User:**
> open a pr and switch branch to test before merging

Claude pushed the branch and opened the PR with `gh pr create`, then
pointed the cluster at the branch to validate before merging:

```bash
just switch-branch fix/prometheus-scrape-alerts
```

This is the sanctioned bootstrap path — `pb_all.yml --tags cluster`
with `-e repo_branch=...`. The playbook re-applied the admission secret
(now via the corrected script), and ArgoCD reconciled the
`grafana-prometheus` Application with the new Helm values.

After cycling the operator and Prometheus pods to pick up the new cert
bundle (`kubectl delete pod -l app=...` — the Deployment recreates them
without touching the ArgoCD-managed spec), Claude validated the
end-state:

```bash
# All scrape targets healthy
kubectl -n monitoring exec prometheus-...-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/targets?state=active' \
  | jq '[.data.activeTargets[] | .health] | group_by(.) | map({(.[0]): length}) | add'
# {"up": 33}

# K3s component rules removed from the loaded ruleset
kubectl -n monitoring get prometheusrule -o jsonpath='{...}' \
  | grep -E 'KubeScheduler|KubeProxy|KubeController'
# (no output)

# ArgoCD app healthy
kubectl -n argo-cd get application grafana-prometheus \
  -o jsonpath='{.status.health.status} {.status.sync.status}'
# Healthy Synced

# Only the always-firing heartbeat alert remains active
kubectl -n monitoring exec alertmanager-...-0 -c alertmanager -- \
  wget -qO- 'http://localhost:9093/api/v2/alerts?active=true&silenced=false' \
  | jq '[.[] | .labels.alertname]'
# ["Watchdog"]
```

All four firing alerts cleared. PR merged.

## What this illustrates

A few things that make this kind of session work well in practice:

**Read-only kubectl is the bulk of the work.** Claude spent most of the
session running `kubectl get`, `kubectl exec ... wget`, and parsing JSON
responses. None of those mutate cluster state, so the human never has
to micro-approve them. The `Bash(kubectl get *)` allow-list in
[claude-code.md](claude-code.md) is what makes that practical.

**The user's domain knowledge sets the direction.** Claude's first
draft of the fix would have ripped out TLS to make the alert go away.
A one-line nudge from the user ("is TLS usually enabled?") reframed it
into the *right* fix without having to write out the reasoning. When
working with an AI agent, treat its first proposal as a starting point
for discussion, not the final answer.

**All durable fixes go through GitOps.** The cluster mutations Claude
made directly (deleting pods to force a re-mount, reapplying a Secret
via the sanctioned script) are all of the "self-healing" variety —
deleting a pod is reversible because the Deployment recreates it; the
Secret reapply is part of the bootstrap path documented in `CLAUDE.md`.
The actual *fix* is in the repo, applied by ArgoCD, surviving any
future rebuild. This is the rule from `CLAUDE.md`:

> Never mutate the live cluster — no `kubectl apply/patch/edit/delete`
> on ArgoCD-managed resources. All fixes go through the CD pipeline:
> change the repo, push, let ArgoCD sync.

**Validate against the cluster, not in your head.** `just switch-branch`
exists specifically so a feature branch can be exercised end-to-end
against the real cluster before merging. Claude used it to confirm:
the playbook still runs cleanly, ArgoCD still reaches Synced+Healthy,
the scrape targets are actually up, and the alerts have actually
cleared. Catching a regression on a branch is cheap; catching it after
merge to `main` is not.

**The failure modes are usually two layers deep.** The visible symptom
("four alerts firing") masked two unrelated bugs that happened to
manifest at the same time. A bot that stops at the first plausible
cause would have fixed half of it and called it done. The discipline
of dumping *all* unhealthy scrape targets and grouping them by job
made it obvious that there were two stories, not one.

## See also

- [Using Claude Code](claude-code.md) — devcontainer setup, permission
  tiers, and credential isolation.
- [GitOps flow](../explanations/gitops-flow.md) — why repo-first fixes
  are the rule on this cluster.
- [Monitoring](monitoring.md) — Grafana / Prometheus / Alertmanager
  configuration and dashboards.
