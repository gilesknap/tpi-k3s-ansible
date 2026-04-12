# CLAUDE.md

## Hard Rules

- **Never mutate the live cluster** — no `kubectl apply/patch/edit/delete`
  on ArgoCD-managed resources. All fixes go through the CD pipeline: change
  the repo, push, let ArgoCD sync. Read-only kubectl (`get`, `describe`,
  `logs`, `exec`, `port-forward`) is fine.
  Exceptions: `kubeseal` (reads the cluster key; output is committed);
  `ansible-playbook --tags cluster` (sanctioned bootstrap/update path);
  `kubectl annotate ... argocd.argoproj.io/refresh=hard` (force repo re-fetch).
- **Never commit to `main`** — work in branches, merge when verified. Use
  `/pr-squash` to tidy history before merging.
- **Rebase over `main` before new work** — squash-merged commits have
  different SHAs from the originals, so skipping rebase causes phantom
  conflicts.
- **Chrome browser is not incognito** — never navigate to Google services.
  For GitHub: OAuth "Grant Access" / "Authorize" clicks are OK (they only
  redirect back to the cluster), but do not modify any GitHub resources
  via Chrome — use `gh`/`curl` for that.
- **Docs are generic** — this repo is intended to be reusable across
  clusters. Write all docs for a general audience. Specific node names
  (ws03, nuc2, node01) are fine as labelled examples.
- **Local PV data paths are sacred.** `/home/k8s-data/*` (nuc2) and
  `/var/lib/k8s-data/*` (RK1s) back the static `local-nvme` PVs that
  carry Supabase/Grafana/Prometheus/Open-WebUI state across rebuilds.
  Do not wipe them. `pb_decommission.yml` preserves them by default;
  only `-e wipe_local_data=true` (opt-in, destructive) removes them.
- **New RWO `local-nvme` workloads must pin a host explicitly.** The
  existing pinning is prometheus→node02, grafana→node03,
  open-webui→node04, supabase-db/storage/minio→nuc2. Each local PV in
  `additions/local-storage/` has `spec.nodeAffinity` matching its pod;
  a new workload needs its own PV + node choice, not a shared pool.

## Testing Rebuild-Affecting Changes

Changes to Ansible roles, secret derivation, CoreDNS, or ArgoCD app
templates can silently break the rebuild path while the live cluster
stays healthy. Before merging such a PR, suggest validating it with
`/rebuild-cluster` on the PR branch — the command handles the PR-test
workflow, including cherry-picking the reseal commit back.

## Key Paths

- Playbook: `pb_all.yml` (not `site.yml`); decommission: `pb_decommission.yml`
- All Ansible vars: `group_vars/all.yml`
- All Helm/ArgoCD values: `kubernetes-services/values.yaml`
- ArgoCD app templates: `kubernetes-services/templates/`
- Extra manifests: `kubernetes-services/additions/` (incl. `ingress/` sub-chart)
- SSH to nodes: `ssh ansible@<node>` (not root)
- ArgoCD namespace: `argo-cd` (hyphenated, not `argocd`)
- kubectl works in the devcontainer — never SSH to nodes for kubectl

## Conventions

- Ansible: 2-space indent, sentence-case task names, idempotent tasks
- Kubernetes: `templates/` = ArgoCD Application CRDs; `additions/` = plain YAML or Helm values
- Lint: `ansible-lint` (suppress with `# noqa <rule>`)
- Docs: `python -m sphinx docs docs/_build`
- `.gitleaks.toml` allowlists `*-secret.yaml` (singular). Files named
  `*-secrets.yaml` (plural) will be blocked by pre-commit — see
  `/sealed-secrets` skill.

## On-Demand Knowledge

Use the `/ansible`, `/oauth`, `/sealed-secrets`, and `/cloudflare` skills
for deeper domain context (branch switching, topology rules, OAuth
gotchas, secret rotation, tunnel config).
