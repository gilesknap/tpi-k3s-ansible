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
- **Use `uv run`** for git commits (pre-commit hooks need the uv venv).
- **Chrome browser is not incognito** — never navigate to Google services.
  For GitHub: OAuth "Grant Access" / "Authorize" clicks are OK (they only
  redirect back to the cluster), but do not modify any GitHub resources
  via Chrome — use `gh`/`curl` for that.
- **Docs are generic** — this repo is intended to be reusable across
  clusters. Write all docs for a general audience. Specific node names
  (ws03, nuc2, node01) are fine as labelled examples.

## Testing Rebuild-Affecting Changes

Changes to Ansible roles, secret derivation, CoreDNS, or ArgoCD app
templates can silently break the rebuild path while the live cluster
stays healthy. Validate with a full rebuild **before** merging:

1. Push your change to a feature branch and `just switch-branch <branch>`
   to point the live cluster at it.
2. Open a PR (draft is fine).
3. `/rebuild-cluster on this branch to test #<PR>` — the skill branches
   off your PR, decommissions, and rebuilds against that branch.
4. If the rebuild surfaces bugs, fix them and cherry-pick the fix
   commit(s) onto the PR branch (force-push).
5. **Cherry-pick the playbook-generated `Re-seal all secrets for
   rebuilt cluster` commit onto the PR branch as a separate commit.**
   One merge must deliver both the code fix *and* the new sealed
   secrets — otherwise `main` keeps the old (un-decryptable)
   ciphertexts and the cluster can't be safely pointed back at `main`
   after merge.
6. Merge the PR, then `ansible-playbook pb_all.yml --tags cluster` to
   switch ArgoCD tracking back to `main`. Delete the rebuild branch.

## Key Paths

- Playbook: `pb_all.yml` (not `site.yml`); decommission: `pb_decommission.yml`
- All Ansible vars: `group_vars/all.yml`
- All Helm/ArgoCD values: `kubernetes-services/values.yaml`
- ArgoCD app templates: `kubernetes-services/templates/`
- Extra manifests: `kubernetes-services/additions/` (incl. `ingress/` sub-chart)
- SSH to nodes: `ssh ansible@<node>` (not root)

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
