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
- **Branch switching** — only edit `group_vars/all.yml` `repo_branch`, then
  run `--tags cluster`. The root app passes it down to all child apps.
- **`known_hosts` task must be `serial: 1`** — parallel writes race.
- **Traefik is disabled** — project uses `--disable=traefik` with NGINX Ingress.
- **Multi-homed nodes** — K3s and flannel auto-detect the IP from the default
  route, which may be the wrong subnet. Set `node_ip` and `flannel_iface` in
  `hosts.yml` for any node with multiple NICs.
- **Chrome browser is not incognito** — never navigate to Google services or
  GitHub in browser automation. The browser has active logged-in sessions.
  Use CLI tools (`gh`, `curl`, `kubectl`) instead.
- **No automated tests** — validate by running playbook tags against the cluster.
- **`gh pr edit` fails on this repo** — classic projects warning causes a
  GraphQL error. Use `gh api repos/OWNER/REPO/pulls/N -X PATCH -f body=...`
  instead.
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

## Key Paths

- Playbook: `pb_all.yml` (not `site.yml`)
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
