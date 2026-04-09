# CLAUDE.md

## Hard Rules

- **Never mutate the live cluster** — no `kubectl apply/patch/edit/delete`
  on ArgoCD-managed resources. All fixes go through the CD pipeline: change the
  repo, push, let ArgoCD sync. Read-only kubectl (`get`, `describe`, `logs`,
  `exec`, `port-forward`) is fine.
  Exceptions: `kubeseal` (reads cluster key; output is committed to repo);
  `ansible-playbook --tags cluster` (sanctioned bootstrap/update path);
  `kubectl annotate ... argocd.argoproj.io/refresh=hard` (force repo re-fetch).
- **Never commit to `main`** — work in branches, merge when verified.
  Use `/pr-squash` to tidy history before merging when needed.
- **Rebase over `main` before new work** — if a branch has had PRs
  merged to `main` (especially squash-merged via `/pr-squash`), rebase
  it onto `origin/main` before making further changes. Squash-merged
  commits have different SHAs from the originals, so skipping this
  causes unnecessary conflicts.
- **Use `uv run`** for git commits (pre-commit hooks need the uv venv).

## Foot-Guns

- **Ansible `k8s` module merges annotations** — it never removes annotations
  that were previously set on an Ingress. If you remove annotations from a
  template (e.g. `ssl-passthrough`), you must `kubectl delete` the old
  Ingress first, then re-run the playbook to recreate it cleanly.
- **oauth2-proxy `email_domains` must be `[]`** — the Helm chart defaults
  to `email_domains = ["*"]`, which allows any GitHub user through and
  silently overrides `authenticatedEmailsFile`. The fix is
  `config.configFile` with `email_domains = []`. This bug was found and
  fixed in PR #279 — do not remove the `configFile` override.
- **oauth2-proxy cookie-secret must be exactly 16, 24, or 32 bytes** —
  `base64.b64encode(token_bytes(32))` produces 44 chars and crashes
  oauth2-proxy. Use `secrets.token_hex(16)` (32 hex chars = 32 bytes).
  This bug has been fixed and regressed before — do not change the
  cookie-secret generation in `scripts/seal-argocd-dex`.
- **Re-sealing secrets requires pod restarts** — `seal-argocd-dex` now
  restarts affected pods automatically. If you re-seal secrets manually
  or via a different path, you must restart pods in `argocd-monitor`,
  `monitoring` (grafana), `open-webui`, and `headlamp` namespaces.
  Env vars from K8s Secrets are snapshot-at-startup; running pods keep
  stale values until restarted.
- **DEX duplicate `argo-cd` static client** — ArgoCD auto-generates an
  `argo-cd` DEX client (without `trustedPeers`). Our `dex.config` also
  declares one (with `trustedPeers: [argocd-monitor]`). DEX v2.45+
  stores the first and drops the duplicate, so `trustedPeers` never
  takes effect. Fixed by adding `oidc.config` with
  `allowedAudiences: [argo-cd, argocd-monitor]` in PR #297, which
  lets argocd-monitor authenticate as itself (no cross-client scope).
  The duplicate `argo-cd` client in `dex.config` is harmless but
  redundant — kept for clarity about the intended `trustedPeers`.
- **Playbook tag for packages is `servers`**, not `update_packages`.
  `--tags update_packages` silently does nothing.
- **Branch switching** — use `just switch-branch <branch>` to point the
  cluster at a different branch. This passes `-e repo_branch=<branch>` as
  an override without editing `group_vars/all.yml`. Never change
  `repo_branch` in `all.yml` — it must always be `main`. To revert,
  run `just switch-branch main`.
- **`known_hosts` task must be `serial: 1`** — parallel writes race.
- **Traefik is disabled** — project uses `--disable=traefik` with NGINX Ingress.
- **Multi-homed nodes** — K3s and flannel auto-detect the IP from the default
  route, which may be the wrong subnet. Set `node_ip` and `flannel_iface` in
  `hosts.yml` for any node with multiple NICs.
- **Control plane (node01) is tainted `NoSchedule`** — DaemonSets without a
  matching toleration won't schedule there, so it can safely be skipped when
  running `--tags servers` for node-level drivers (e.g. DRA plugins).
- **Chrome browser is not incognito** — never navigate to Google services
  in browser automation. For GitHub: do not use Chrome to modify any
  GitHub resources (repos, issues, PRs, settings). OAuth "Grant Access"
  / "Authorize" clicks are OK — they only redirect back to the cluster.
  For all other GitHub work, use CLI tools (`gh`, `curl`) instead.
- **No automated tests** — validate by running playbook tags against the cluster.
- **Dex/Grafana need restart after re-sealing** — pods that read secrets
  via `envFrom` or `secretKeyRef` cache values at startup. After
  `--tags cluster` or `just seal-argocd-dex`, run `just restart-dex`
  and restart Grafana (`kubectl rollout restart sts grafana-prometheus -n monitoring`).
  Without this, Dex reports "invalid client_secret" even though the
  Kubernetes Secret objects match.
- **`gh pr edit` fails on this repo** — classic projects warning causes a
  GraphQL error. Use `gh api repos/OWNER/REPO/pulls/N -X PATCH -f body=...`
  instead.
- **ws03 workstation taint** — any DaemonSet that needs to schedule on ws03
  must tolerate `workstation=true:NoSchedule`. The nvidia-device-plugin
  template includes this; check other DaemonSets if they need ws03.
  Longhorn does **not** tolerate this taint — ws03 is treated as
  unreliable (may reboot), so no Longhorn storage runs there.
  Monitoring statefulsets (Grafana, Prometheus) tolerate the taint for
  metrics collection but must have `nodeAffinity` excluding ws03, or
  their Longhorn PVCs will be provisioned there and fail to attach.
- **Decommission before ArgoCD** — when tearing down the cluster, delete
  all ArgoCD Applications (orphan cascade) *before* scaling down workloads.
  Otherwise ArgoCD reconciliation re-creates pods faster than you can
  remove them. After controller uninstall, strip finalizers from Longhorn
  CRD resources (volumes, engines, etc.) since the controller is gone.
- **Prometheus operator admission secret** — kube-prometheus-stack's
  webhook TLS secret (`grafana-prometheus-kube-pr-admission`) is not
  auto-created on ArgoCD-managed installs (Helm hook job is pruned).
  Run `just create-prometheus-admission-secret` to create it.
- **ArgoCD valuesObject overrides values.yaml** — for child apps like
  `open-brain-mcp`, the image tag is set in `templates/*.yaml` `valuesObject`,
  not in `additions/*/values.yaml`. Changing only `values.yaml` has no effect.
- **`admin_emails` is duplicated** — must be kept in sync between
  `kubernetes-services/values.yaml` (Helm) and `group_vars/all.yml`
  (Ansible). After changing the Ansible copy, re-run `--tags cluster`.

Auth/OAuth foot-guns are in the `/oauth` skill. Cloudflare foot-guns are in the `/cloudflare` skill.

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
