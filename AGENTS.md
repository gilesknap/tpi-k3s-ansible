# AGENTS.md — Guidance for AI Coding Agents

## Testing Before Committing

Do not offer to commit or push until the user has tested the changes.

After implementing any change:
1. Tell the user what changed and how to test it
2. Wait for confirmation
3. Only `git commit` / `git push` when explicitly asked

---

## GitOps: Fix in the Repo, Never in the Cluster

ArgoCD manages all cluster state. Direct `kubectl apply/patch/edit` will be
reverted by self-heal or create hidden drift.

**Correct workflow:**
1. Edit files in the repo
2. `git commit` and `git push`
3. ArgoCD reconciles automatically

Read-only kubectl (`get`, `logs`, `describe`) is fine for diagnosis.

**Exception:** `kubeseal` reads the cluster's public key, but the resulting
SealedSecret is committed to the repo.

See: `docs/explanations/gitops-flow.md`

---

## Ansible: Update Roles, Not Ad-hoc Commands

All node configuration lives in `roles/`. Encode changes in the appropriate
role so they are applied idempotently on every future provisioning.

**Key roles:**

| Role | Purpose | Tag |
|------|---------|-----|
| `roles/update_packages` | OS packages on all nodes | `servers` |
| `roles/tools` | CLI tools (helm, kubectl, kubeseal) | `tools` |
| `roles/k3s` | K3s installation and config | `k3s` |
| `roles/cluster` | ArgoCD bootstrap and cluster setup | `cluster` |

**The playbook tag for node packages is `servers`, NOT `update_packages`.**
`--tags update_packages` silently does nothing.

```bash
# All nodes
ansible-playbook pb_all.yml --tags servers
# Specific nodes
ansible-playbook pb_all.yml --tags servers --limit node02,node03
```

See: `docs/reference/playbook-tags.md`

---

## Project Structure

**Two-file configuration** — all customisation lives in:
- `group_vars/all.yml` — Ansible variables (bootstrap time)
- `kubernetes-services/values.yaml` — ArgoCD Helm values (runtime)

See: `docs/reference/variables.md`

### Services directory

```
kubernetes-services/
├── values.yaml
├── templates/              # One ArgoCD Application per service
│   ├── cert-manager.yaml
│   ├── cloudflared.yaml
│   ├── dashboard.yaml      # Headlamp
│   ├── echo.yaml
│   ├── grafana.yaml
│   ├── ingress.yaml
│   ├── kernel-settings.yaml
│   ├── llamacpp.yaml
│   ├── longhorn.yaml
│   ├── nvidia-device-plugin.yaml
│   ├── oauth2-proxy.yaml
│   ├── open-webui.yaml
│   ├── rkllama.yaml
│   └── sealed-secrets.yaml
└── additions/              # Extra manifests per service
    ├── argocd/
    ├── cert-manager/
    ├── cloudflared/
    ├── dashboard/
    ├── echo/
    ├── ingress/            # Reusable ingress sub-chart
    ├── llamacpp/
    ├── longhorn/
    ├── oauth2-proxy/
    └── rkllama/
```

See: `docs/explanations/kubernetes-services.md`, `docs/how-to/add-remove-services.md`

### Reusable ingress sub-chart

`additions/ingress/` generates standardised Ingress resources. Supported toggles:
- `oauth2_proxy: true` — protect with oauth2-proxy
- `ssl_redirect: true/false` — HTTP→HTTPS redirect (default true)
- `ssl_passthrough: true` — TLS passthrough mode
- `basic_auth: true` — nginx basic-auth via `admin-auth` secret

### OAuth2 architecture

oauth2-proxy is a **gateway** only — services retain their native login/RBAC.
- Protected: Grafana, Longhorn, Headlamp, Open WebUI
- Not behind OAuth: ArgoCD (TLS passthrough, own login), RKLlama (internal API)
- Email allowlist in `kubernetes-services/values.yaml` as `oauth2_emails`

See: `docs/how-to/oauth-setup.md`

---

## GitOps Flow

1. Ansible `cluster` role installs ArgoCD and creates the root Application
2. ArgoCD reads `kubernetes-services/` from the configured repo/branch
3. Each template becomes an auto-syncing child Application (prune + self-heal)
4. **To update services: push to git** — ArgoCD picks it up automatically

See: `docs/explanations/gitops-flow.md`

---

## Dual `repo_branch` — Always Update Both

Two separate `repo_branch` variables must stay in sync:
1. **`group_vars/all.yml`** — Ansible bootstrap (creates root Application CR)
2. **`kubernetes-services/values.yaml`** — ArgoCD runtime (`targetRevision`)

They cannot be unified — consumed by different systems at different stages.

If switching the root app to a different branch and the old value persists:
```bash
kubectl patch application all-cluster-services -n argo-cd --type json \
  -p '[{"op":"remove","path":"/spec/source/helm/valuesObject/repo_branch"}]'
```

See: `docs/how-to/work-in-branches.md`

---

## Coding Conventions

### Ansible
- **Idempotency:** use `creates:`, `when:`, stat checks, or registration
- **Force flags:** `do_flash`, `k3s_force`, `cluster_force` — all default false
- **Linting:** `ansible-lint` in devcontainer; suppress with `# noqa <rule>`
- **YAML:** 2-space indent, sentence-case task names

### Kubernetes manifests
- Templates in `templates/` are ArgoCD Application CRDs
- Additions in `additions/` are plain YAML or Helm values
- Use the reusable `additions/ingress/` sub-chart for ingress

### Git workflow
- Use `uv run` to execute git commits (pre-commit hooks need the uv venv)
- Playbook is `pb_all.yml` (not `site.yml`)
- `.gitleaks.toml` allowlists `*-secret.yaml` so SealedSecrets don't trigger false positives
- Docs build: `python -m sphinx docs docs/_build`

---

## Inventory Conventions

- **Node groups:** Turing Pi groups must be named `<bmc_hostname>_nodes`
  (e.g. `turingpi_nodes` for BMC host `turingpi`)
- **Per-node vars:** `slot_num` (1-4), `type` (`rk1`/`pi4`), `root_dev` (NVMe target)
- **Groups:** `all_nodes` = all Turing Pi groups + `extra_nodes`

See: `docs/reference/inventory.md`

---

## Important Warnings

1. **`tpi flash` USB errors** — power-cycle the BMC (not just nodes). BMC firmware bug.
2. **`known_hosts` must be `serial: 1`** — parallel writes cause race conditions.
3. **Traefik disabled** — K3s ships Traefik but this project uses `--disable=traefik` with NGINX Ingress.
4. **No automated tests** — validate by running playbook tags against the cluster.

---

## Cloudflare Tunnel UI

The Zero Trust dashboard has no separate "Service Type" field. Specify the
protocol as a URL prefix: `http://hostname:port` or `https://hostname:port`.

See: `docs/how-to/cloudflare-tunnel.md`

---

## TODO

- **Scope down Headlamp RBAC:** replace `cluster-admin` with a custom
  ClusterRole in `kubernetes-services/additions/dashboard/rbac.yaml`
