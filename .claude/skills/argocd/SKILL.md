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

## Spotting which validator is failing

Three distinct conditions, three distinct fixes:

| Condition | Where it fires | What to fix |
|---|---|---|
| `InvalidSpecError: application repo X is not permitted in project Y` | App-controller, against AppProject | Add `X` to `sourceRepos` in `argo-cd/argo-project.yaml`, re-apply with `--tags cluster`, bounce app-controller |
| `ComparisonError: failed to resolve revision ...: 403/404` | Repo-server, against the remote registry | OCI URL wrong (see oci:// trap above) or chart genuinely missing/private |
| `ComparisonError: values don't meet the specifications of the schema(s)` | Repo-server, helm template | Chart's `values.schema.json` rejects your `valuesObject` — check `additionalProperties: false`, key casing, etc. |

The first two often appear *together* when the project allowlist and
URL form are both wrong; fixing only one leaves the app still Unknown.
