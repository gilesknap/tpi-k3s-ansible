# CLAUDE.md

## Hard Rules

- **Never mutate the live cluster** — no `kubectl apply/patch/edit/delete`
  on ArgoCD-managed resources. All fixes go through the CD pipeline: change the
  repo, push, let ArgoCD sync. Read-only kubectl (`get`, `describe`, `logs`,
  `exec`, `port-forward`) is fine.
  Exceptions: `kubeseal` (reads cluster key; output is committed to repo);
  `ansible-playbook --tags cluster` (sanctioned bootstrap/update path);
  `kubectl annotate ... argocd.argoproj.io/refresh=hard` (force repo re-fetch).
- **Never commit to `main`** — work in branches, squash-merge when verified.
- **Use `uv run`** for git commits (pre-commit hooks need the uv venv).

## Foot-Guns

- **Ansible `k8s` module merges annotations** — it never removes annotations
  that were previously set on an Ingress. If you remove annotations from a
  template (e.g. `ssl-passthrough`), you must `kubectl delete` the old
  Ingress first, then re-run the playbook to recreate it cleanly.
- **Playbook tag for packages is `servers`**, not `update_packages`.
  `--tags update_packages` silently does nothing.
- **Branch switching** — only edit `group_vars/all.yml` `repo_branch`, then
  run `--tags cluster`. The root app passes it down to all child apps.
- **`known_hosts` task must be `serial: 1`** — parallel writes race.
- **Traefik is disabled** — project uses `--disable=traefik` with NGINX Ingress.
- **Multi-homed nodes** — K3s and flannel auto-detect the IP from the default
  route, which may be the wrong subnet. Set `node_ip` and `flannel_iface` in
  `hosts.yml` for any node with multiple NICs.
- **Control plane (node01) is tainted `NoSchedule`** — DaemonSets without a
  matching toleration won't schedule there, so it can safely be skipped when
  running `--tags servers` for node-level drivers (e.g. DRA plugins).
- **Chrome browser is not incognito** — never navigate to Google services or
  GitHub in browser automation. The browser has active logged-in sessions.
  Use CLI tools (`gh`, `curl`, `kubectl`) instead.
- **ArgoCD Dex audiences are hardcoded** — `server.additional.audiences` does
  nothing for Dex. Override the `argo-cd` client in `dex.config` with
  `trustedPeers` instead. See `additions/argocd/README.md`.
- **`oidc.config` disables Dex** — having `oidc.config` in argocd-cm causes
  `IsDexDisabled()=true`. Use `dex.config` only.
- **Re-sealing secrets requires pod restart** — pod env vars from `secretKeyRef`
  are read at startup. After `just seal-argocd-dex`, restart affected pods.
- **Dex secret needs ArgoCD label** — the `argocd-dex-secret` SealedSecret
  template must include `app.kubernetes.io/part-of: argocd` label. Without
  it, ArgoCD's `$secret:key` resolution in `dex.config` silently fails,
  passing literal key names as OAuth client IDs (→ GitHub 404).
- **No automated tests** — validate by running playbook tags against the cluster.
- **`gh pr edit` fails on this repo** — classic projects warning causes a
  GraphQL error. Use `gh api repos/OWNER/REPO/pulls/N -X PATCH -f body=...`
  instead.
- **Ingress auth-url must be cluster-internal** — the ingress sub-chart's
  `auth-url` uses the internal service (`oauth2-proxy.oauth2-proxy.svc`).
  Using the external domain resolves via Cloudflare to IPv6, which is
  unreachable from the cluster, causing intermittent 500s on all
  oauth2-protected ingresses.
- **ws03 workstation taint** — any DaemonSet that needs to schedule on ws03
  must tolerate `workstation=true:NoSchedule`. The nvidia-device-plugin
  template includes this; check other DaemonSets if they need ws03.
  Longhorn's `longhornManager`/`longhornDriver` tolerations and
  `defaultSettings.taintToleration` are set in `templates/longhorn.yaml`
  so CSI plugin + engine-image also run on ws03.
- **Decommission before ArgoCD** — when tearing down the cluster, delete
  all ArgoCD Applications (orphan cascade) *before* scaling down workloads.
  Otherwise ArgoCD reconciliation re-creates pods faster than you can
  remove them. After controller uninstall, strip finalizers from Longhorn
  CRD resources (volumes, engines, etc.) since the controller is gone.
- **Prometheus operator admission secret** — kube-prometheus-stack's
  webhook TLS secret (`grafana-prometheus-kube-pr-admission`) is not
  auto-created on ArgoCD-managed installs (Helm hook job is pruned).
  Run `just create-prometheus-admission-secret` to create it.
- **MCP SDK host validation** — `FastMCP` rejects requests where the `Host`
  header is not in `allowed_hosts` (421 Misdirected Request). When deploying
  behind a reverse proxy, add the external hostname via `transport_security`.
- **ArgoCD valuesObject overrides values.yaml** — for child apps like
  `open-brain-mcp`, the image tag is set in `templates/*.yaml` `valuesObject`,
  not in `additions/*/values.yaml`. Changing only `values.yaml` has no effect.
- **Supabase SQL migrations only run on DB init** — adding a new migration
  SQL block won't execute on an existing database. Run it manually via
  `kubectl exec` or the Supabase Storage API.
- **MinIO persistence key is `persistence.minio`** — not `persistence.storage`
  (which maps to the Supabase Storage component, a different thing).
- **Dex base URL redirects** — `/api/dex` 301s to `/api/dex/` which returns
  404. OIDC clients that don't follow redirects (e.g. Open WebUI's authlib)
  need the full discovery URL: `.well-known/openid-configuration`.
- **Cloudflare tunnel sends `http://` redirect_uri** — services behind the
  tunnel with `ssl_redirect: false` generate `http://` OAuth callbacks. Dex
  static clients must list both `http://` and `https://` redirect URIs.
- **Grafana 12.x requires `[users].allow_sign_up`** — the per-provider
  `allow_sign_up` under `[auth.generic_oauth]` is not sufficient alone.
  Also set `[auth].disable_signup_form: true` to block manual signup.
- **`admin_emails` is duplicated** — must be kept in sync between
  `kubernetes-services/values.yaml` (Helm) and `group_vars/all.yml`
  (Ansible). After changing the Ansible copy, re-run `--tags cluster`.
- **Headlamp OIDC doesn't work** — native Dex OIDC was attempted and
  reverted (PR #238). TLS verification and redirect issues. Keep Headlamp
  on oauth2-proxy with token login — 3 auth layers is sufficient.
- **Headlamp Helm `config.oidc.externalSecret` key names** — if OIDC is
  ever revisited, the chart uses `envFrom: secretRef` and references
  `$(OIDC_CLIENT_ID)` etc. Secret keys must be uppercase `OIDC_*`, not
  the camelCase keys the chart generates internally.

## Key Paths

- Playbook: `pb_all.yml` (not `site.yml`)
- Decommission playbook: `pb_decommission.yml`
- All Ansible vars: `group_vars/all.yml`
- All Helm/ArgoCD values: `kubernetes-services/values.yaml`
- ArgoCD app templates: `kubernetes-services/templates/`
- Extra manifests per service: `kubernetes-services/additions/`
- Reusable ingress sub-chart: `kubernetes-services/additions/ingress/`
- SSH to nodes: `ssh ansible@<node>` (not root)

## Documentation

- **Docs are generic** — this repo is intended to be reusable across clusters.
  Write all docs (ADRs, how-tos, explanations) for a general audience.
  Specific node names (ws03, nuc2, node01) are fine as examples but must be
  clearly labelled as such (e.g. "in the author's cluster, ws03 is…").

## Conventions

- Ansible: 2-space indent, sentence-case task names, idempotent tasks
- Kubernetes: templates/ = ArgoCD Application CRDs, additions/ = plain YAML or Helm values
- Lint: `ansible-lint`; suppress with `# noqa <rule>`
- Docs: `python -m sphinx docs docs/_build`
- `.gitleaks.toml` allowlists `*-secret.yaml` (SealedSecrets)
- **SealedSecret file naming** — must be `*-secret.yaml` (singular).
  Files named `*-secrets.yaml` are not in the `.gitleaks.toml` allowlist
  and the pre-commit hook will block the commit with no obvious reason.

## On-Demand Knowledge

Use `/oauth`, `/ansible`, or `/cloudflare` skills for deeper context on those topics.
