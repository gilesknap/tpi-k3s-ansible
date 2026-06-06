---
name: ansible
description: Ansible playbook structure, tags, topology rules, branch switching, and operational foot-guns for the K3s cluster.
---

# Ansible

## Playbook Structure
- Entry point: `pb_all.yml` (NOT `site.yml`)
- Decommission: `pb_decommission.yml`
- Vars: `group_vars/all.yml` — single source of truth for cluster-wide settings
- Inventory: `hosts.yml`
- ArgoCD apps: `kubernetes-services/templates/`; extra manifests in
  `kubernetes-services/additions/`. Reusable ingress sub-chart at
  `kubernetes-services/additions/ingress/`.
- SSH to nodes: `ssh ansible@<node>` (not root).

## Common Tags
- `servers` — system packages, workstation taint/label tasks, NVIDIA
  container runtime on GPU nodes. **Not `update_packages`** — that
  tag silently does nothing.
- `cluster` — ArgoCD root app + all child apps (branch switching,
  service toggles). Sanctioned path for touching ArgoCD-managed state.
- `k3s` — K3s install/configure.
- `known_hosts` — populate `/etc/ssh/ssh_known_hosts`.

## Operational patterns

- **Ansible reaches nodes via the host SSH agent**, forwarded into the
  devcontainer by VS Code Dev Containers (`SSH_AUTH_SOCK` is set
  automatically). Make sure your ansible key is loaded into the host
  agent before opening the container; the sandbox running Claude
  cannot see it, but ordinary devcontainer terminals can.
- **Commits need `uv run`** — pre-commit hooks live in the uv venv.
- **Adding a node**: run `/add-node`.
- **Full bootstrap**: run `/bootstrap-cluster`.
- **Rebuild cluster**: run `/rebuild-cluster`.

## Branch switching

`repo_branch` in `group_vars/all.yml` **must always be `main`** — never
edit it. To point the cluster at a feature branch, use
`just switch-branch <branch>`, which passes `-e repo_branch=<branch>`
as an override. Revert with `just switch-branch main`.

### Check current tracked revision before branching new work

The cluster may already be on a feature branch (e.g. mid-validation of
an open PR), not `main`. Branching new work off `origin/main` then
running `just switch-branch <new-branch>` will silently roll back any
commits that exist only on the previously-tracked branch. The most
painful case is sealed secrets re-sealed during a rebuild: the new
branch applies older (un-decryptable) versions from `main`, the
controller logs `no key could decrypt secret`, and consumer pods drift
from their live Secrets.

Before creating a new working branch:

```bash
kubectl -n argo-cd get application all-cluster-services \
  -o jsonpath='{.spec.sources[*].targetRevision}'
```

If it's not `main`, **stop and ask the user** whether to:
(a) merge the tracked branch to main first, then branch off main, or
(b) base the new work on the currently-tracked branch.

## Topology rules

### Multi-homed nodes
K3s and flannel auto-detect the IP from the default route, which may be
the wrong subnet. Set `node_ip` and `flannel_iface` in `hosts.yml` for
any node with multiple NICs — otherwise CNI traffic goes out the wrong
interface and pod networking silently breaks.

### Control-plane `NoSchedule` taint
The control plane (e.g. node01) is tainted `NoSchedule`. DaemonSets
without a matching toleration won't schedule there, so it can safely
be skipped when running `--tags servers` for node-level drivers (DRA
plugins, etc.).

### Workstation taint (ws03)
Workstation nodes carry `workstation=true:NoSchedule` because they may
reboot unexpectedly. This has three consequences you must design for:

- **DaemonSets that need ws03** must tolerate the taint. The
  `nvidia-device-plugin` template already does; audit any new DaemonSet
  that needs to run there.
- **Longhorn does not tolerate the taint** — no Longhorn storage runs
  on ws03. Anything with a Longhorn PVC must not be scheduled there.
- **Monitoring statefulsets** (Grafana, Prometheus) tolerate the taint
  so they can scrape workstation metrics, but must have a `nodeAffinity`
  rule **excluding** ws03. Otherwise their Longhorn PVCs get provisioned
  on ws03 and fail to attach.
- **amd64-only workloads land on nuc2 by default.** ws03 and nuc2 are the
  only amd64 nodes; ws03's taint means a chart with
  `nodeSelector: kubernetes.io/arch: amd64` pins to nuc2 without any
  explicit hostname selector. Useful for charts whose schema forbids
  `kubernetes.io/hostname` overrides (e.g. thoth).

### Longhorn replica count vs node count
Replica counts in `kubernetes-services/values.yaml` must match the
number of Longhorn-capable nodes (i.e. excluding ws03). Going too high
leaves volumes permanently Degraded; going too low under-replicates on
adds. Update after any `/add-node` run.

## BMC power operations

When a node is `NotReady` and SSH times out, `ansible -m reboot` and the
graceful procedures in `docs/how-to/node-operations.md` cannot help —
both the kubelet and `sshd` on the node are gone. Power-cycle via the
Turing Pi BMC instead.

The BMC is reachable as `{{ tpi_user }}@turingpi` (default `root@turingpi`,
defined in `group_vars/all.yml`). Each slot maps to a node via
`slot_num` in `hosts.yml`: node01→1, node02→2, node03→3, node04→4.
`nuc2` and `ws03` are not on the BMC.

```bash
# What the BMC thinks of all four slots
ssh root@turingpi 'tpi power status'

# Power-cycle a single node (off → wait → on) — the form used by roles/flash
ssh root@turingpi 'tpi power off -n 4 && sleep 15 && tpi power on -n 4'
```

Notes:
- Don't try `kubectl drain` first — the node is unreachable, so the
  drain will just hang. Just power-cycle and let workloads reschedule
  (or come back, for DaemonSets pinned to that node like `rkllama`).
- Hard power-cycle is unclean for in-flight writes. If the node hosts
  live local-PV data (see CLAUDE.md "Local PV data paths are sacred":
  Prometheus on node02, Grafana on node03, Open-WebUI on node04),
  expect fsck on boot — check pod logs once the node returns.
- For the Claude sandbox specifically: the BMC SSH key isn't reachable
  from the sandbox (the `--clearenv` bwrap wrapper strips `SSH_AUTH_SOCK`
  and the BMC host key isn't in the sandbox's `known_hosts`). The `!`
  prompt prefix runs inside the same sandbox, so it doesn't help — ask
  the user to run `ssh root@turingpi 'tpi power ...'` from a regular
  devcontainer terminal or the host shell.

## Foot-guns

- **`known_hosts` task must run `serial: 1`** — parallel writes cause
  race conditions on the shared file.
- **Traefik is disabled** — `--disable=traefik` with NGINX Ingress. Do
  not assume Traefik CRDs exist.
- **No automated tests** — validate by running playbook tags against
  the live cluster.
- **Ansible `k8s` module merges annotations** — it never removes
  annotations that were previously set on an Ingress. If you remove
  annotations from a template (e.g. `ssl-passthrough`), you must
  `kubectl delete` the old Ingress first, then re-run the playbook to
  recreate it cleanly.
- **ArgoCD `valuesObject` overrides `values.yaml`** — for child apps
  like `open-brain-mcp`, the image tag is set in `templates/*.yaml`
  under `valuesObject`, not in `additions/*/values.yaml`. Editing
  `values.yaml` alone has no effect — check the template first.
- **`admin_emails` is duplicated** — must be kept in sync between
  `kubernetes-services/values.yaml` (Helm) and `group_vars/all.yml`
  (Ansible). After changing the Ansible copy, re-run `--tags cluster`.
- **Prometheus admission webhook secret** — `kube-prometheus-stack`'s
  TLS secret (`grafana-prometheus-kube-pr-admission`) is not created by
  the Helm hook job under ArgoCD. The `cluster` role creates it via
  `scripts/create-prometheus-admission-secret`. If the operator is
  still CrashLooping after a rebuild, run
  `just create-prometheus-admission-secret` directly then delete the
  stuck pod.
- **Decommission before ArgoCD** — when tearing down the cluster, the
  decommission playbook deletes ArgoCD Applications (orphan cascade)
  *before* scaling down workloads. Doing it in the other order means
  ArgoCD reconciliation re-creates pods faster than you can remove
  them. After controller uninstall, strip finalizers from Longhorn
  CRD resources (volumes, engines, etc.) since the controller is gone.
- **`gh pr edit` fails on this repo** — classic projects warning
  causes a GraphQL error. Use
  `gh api repos/OWNER/REPO/pulls/N -X PATCH -f body=...` instead.

## Key files
- `pb_all.yml` — main playbook
- `pb_decommission.yml` — teardown
- `group_vars/all.yml` — all variables
- `hosts.yml` — inventory with node vars
- `roles/` — Ansible roles
