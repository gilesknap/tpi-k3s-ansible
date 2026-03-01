# CLAUDE.md

## Hard Rules

- **Never commit/push** without asking.
- **Never `kubectl apply/patch/edit`** — ArgoCD self-heals. Read-only kubectl is fine.
  Exception: `kubeseal` (reads cluster key; output is committed to repo).
- **Never commit to `main`** — work in branches, squash-merge when verified.
- **Use `uv run`** for git commits (pre-commit hooks need the uv venv).

## Foot-Guns

- **Playbook tag for packages is `servers`**, not `update_packages`.
  `--tags update_packages` silently does nothing.
- **Dual `repo_branch`** — must update both `group_vars/all.yml` AND
  `kubernetes-services/values.yaml` when switching branches. They cannot be
  unified (Ansible bootstrap vs ArgoCD runtime).
- **`known_hosts` task must be `serial: 1`** — parallel writes race.
- **Traefik is disabled** — project uses `--disable=traefik` with NGINX Ingress.
- **No automated tests** — validate by running playbook tags against the cluster.

## Key Paths

- Playbook: `pb_all.yml` (not `site.yml`)
- All Ansible vars: `group_vars/all.yml`
- All Helm/ArgoCD values: `kubernetes-services/values.yaml`
- ArgoCD app templates: `kubernetes-services/templates/`
- Extra manifests per service: `kubernetes-services/additions/`
- Reusable ingress sub-chart: `kubernetes-services/additions/ingress/`
- SSH to nodes: `ssh ansible@<node>` (not root)

## Conventions

- Ansible: 2-space indent, sentence-case task names, idempotent tasks
- Kubernetes: templates/ = ArgoCD Application CRDs, additions/ = plain YAML or Helm values
- Lint: `ansible-lint`; suppress with `# noqa <rule>`
- Docs: `python -m sphinx docs docs/_build`
- `.gitleaks.toml` allowlists `*-secret.yaml` (SealedSecrets)

## On-Demand Knowledge

Use `/oauth`, `/ansible`, or `/cloudflare` skills for deeper context on those topics.
