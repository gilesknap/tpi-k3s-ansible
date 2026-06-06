---
name: argocd
description: ArgoCD operations on the K3s cluster — branch repointing via ansible, OCI Helm chart wiring foot-guns (oci:// prefix breaks chart-name resolution), and the InvalidSpecError cache bounce.
---

# ArgoCD

The cluster runs an app-of-apps. The root `Application` is
`all-cluster-services` in namespace `argo-cd`; it templates the child
Applications under `kubernetes-services/templates/` from this repo.

## Branch repointing (smoke-testing a PR branch)

Don't `kubectl edit` the root Application. The sanctioned path:

1. Edit `group_vars/all.yml` → set `repo_branch: <branch>`. Do NOT commit
   this — it's a local-only smoke pointer.
2. `uv run ansible-playbook pb_all.yml --tags cluster` — re-templates the
   root app and applies it. This is one of the few commands in the hard
   rules that's allowed to mutate the live cluster.
3. If child apps don't pick up the new revision within a minute, force a
   re-fetch on the root:
   ```
   kubectl -n argo-cd annotate application all-cluster-services \
     argocd.argoproj.io/refresh=hard --overwrite
   ```
4. Reset `repo_branch: main` when done.

### Don't push an unpublished chart pin while ArgoCD watches that branch

While `repo_branch` points at a PR/dev branch for a smoke test, ArgoCD
syncs from the *pushed* tip of that branch. So bumping an OCI chart pin
(e.g. `chart_version`/`image_tag` in `kubernetes-services/values.yaml`)
to a tag that isn't on the registry yet and **pushing** it makes ArgoCD
fail the next sync with the `ComparisonError: ... 403/404` from the OCI
trap below — the chart genuinely doesn't exist at that version.

When prepping a version bump ahead of the upstream release: keep the
edit out of the pushed branch — park it (a `.parked.md` diff under
`_plans/`, or just leave `values.yaml` untouched and stage the bump
later). Verify the tag is live before applying:

```
helm pull oci://ghcr.io/<org>/charts/<chart> --version <ver>   # 200 = safe to pin
```

Doc edits that merely *mention* the new version are fine to commit early
(they don't deploy); only the `values.yaml` pin is load-bearing.

## OCI Helm charts — `oci://` prefix is a trap

For an OCI-hosted Helm chart (e.g. `ghcr.io/<org>/charts/<chart>`):

- Application `repoURL`: **bare** `ghcr.io/<org>/charts` (no `oci://` prefix)
- Application `chart`: `<chart>` (the sub-path)
- AppProject `sourceRepos`: **must match exactly** — also bare
  `ghcr.io/<org>/charts`

If you use `oci://ghcr.io/<org>/charts` in `repoURL`, ArgoCD's URL
construction drops the chart name and tries to pull
`https://ghcr.io/v2/<org>/charts/manifests/<ver>` instead of
`.../charts/<chart>/manifests/<ver>` — producing a baffling 403 from
ghcr (denied access to the wrong path). The error log line to look for
in `argocd-repo-server`:

```
HEAD "https://ghcr.io/v2/<org>/charts/manifests/<ver>": 
  GET "https://ghcr.io/token?scope=repository:<org>/charts:pull&...": 403: denied
```

If you see that, the fix is to drop `oci://` from both the Application
and the matching `sourceRepos` entry in `argo-cd/argo-project.yaml`.

## InvalidSpecError sticks after AppProject edits

ArgoCD caches the `InvalidSpecError` condition with the original
`lastTransitionTime` — even after you fix the `AppProject`'s
`sourceRepos`, the child app stays `Unknown/Unknown` with the same
stale error. Annotations / refreshes don't clear it.

Bounce the application controller to force re-validation:

```
kubectl -n argo-cd delete pod argocd-application-controller-0
```

It's a StatefulSet, recreates cleanly within seconds. Allowed under
the hard rules — pod lifecycle, not config drift.

## ConfigMap-only changes don't roll the pod (envFrom + no checksum)

If a workload consumes a chart-rendered ConfigMap/Secret via `envFrom`
(or env `valueFrom`), changing **only** the ConfigMap *data* does **not**
restart the pod. Env vars are injected at pod start, and unless the
chart's Deployment pod template carries a `checksum/config` (and
`checksum/secret`) annotation, the Deployment spec is unchanged — so
ArgoCD shows the app **Synced/Healthy while the running pod keeps the
stale values**. Easy to miss: the ConfigMap in the cluster is correct,
but the config is not actually enforced.

Diagnose by comparing the ConfigMap to what the pod actually has:

```
kubectl get cm -n <ns> <cm> -o jsonpath='{.data.<KEY>}'      # new value
kubectl exec -n <ns> <pod> -- printenv <KEY>                  # stale value
```

Enforce it by restarting the pod (the Deployment recreates it identically
— pods aren't ArgoCD-tracked, so this is **no git drift** and allowed
under the hard rules, same as the app-controller bounce above):

```
kubectl delete pod -n <ns> <pod>
```

The real fix is upstream: the chart should add
`checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}`
to the pod template so data changes roll the workload automatically.

## Spotting which validator is failing

Three distinct conditions, three distinct fixes:

| Condition | Where it fires | What to fix |
|---|---|---|
| `InvalidSpecError: application repo X is not permitted in project Y` | App-controller, against AppProject | Add `X` to `sourceRepos` in `argo-cd/argo-project.yaml`, re-apply with `--tags cluster`, bounce app-controller |
| `ComparisonError: failed to resolve revision ...: 403/404` | Repo-server, against the remote registry | OCI URL wrong (see oci:// trap above) or chart genuinely missing/private |
| `ComparisonError: values don't meet the specifications of the schema(s)` | Repo-server, helm template | Chart's `values.schema.json` rejects your `valuesObject` — check `additionalProperties: false`, key casing, etc. |

The first two often appear *together* when the project allowlist and
URL form are both wrong; fixing only one leaves the app still Unknown.
