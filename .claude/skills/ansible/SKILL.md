---
name: ansible
description: Ansible playbook structure, tags, topology rules, branch switching, and operational foot-guns for the K3s cluster.
---

# Ansible

## Playbook Structure
- Entry point: `pb_all.yml` (NOT `site.yml`)
- Decommission: `pb_decommission.yml`
- Router: `pb_router.yml` (host `router`, group `routers`; no Python: `raw`,
  and `script` for the restore's file copy;
  every play tagged `never`: `--tags check|change|dhcp-diff|drill|restore`;
  in the sandbox add `--private-key /root/.config/claude-ssh/id_ed25519`).
  Change the router only through `--tags change` (confirm-or-revert);
  see `docs/how-to/router-recovery.md`. Its `/etc/config/dhcp` is a
  template (`roles/router/templates/dhcp.j2`): nodes reserved by hostname
  from `lan_ip` in hosts.yml, other devices by MAC in `router_dhcp_hosts`;
  `just router-dhcp` previews then applies (`-e router_change_tasks=dhcp`).
  See `docs/how-to/router-dhcp.md`.
- Vars: `group_vars/all.yml` — single source of truth for cluster-wide settings
- Inventory: `hosts.yml`
- ArgoCD apps: `kubernetes-services/templates/`; extra manifests in
  `kubernetes-services/additions/`. Reusable HTTPRoute sub-chart at
  `kubernetes-services/additions/ingress/`.
- SSH to nodes: `ssh ansible@<node>` (not root).

## Common Tags
- `servers` — move_fs, rk1_os, update_packages (packages,
  unattended-upgrades, NVIDIA container runtime on GPU nodes),
  k8s_data_dirs. There is **no `update_packages` tag** — `--tags
  update_packages` silently does nothing.
  Safe to run at any time: `update_packages` never reboots a node that
  runs k3s; it leaves `/var/run/reboot-required` for kured. Add
  `-e reboot_now=true` for a drained reboot now, one node at a time
  (`node_reboot` role, `serial: 1` play). Only a node without k3s yet
  (first provisioning) is rebooted at once; workstations never are.
- `cluster` — ArgoCD root app + all child apps (branch switching,
  service toggles). Sanctioned path for touching ArgoCD-managed state.
- `k3s` — K3s install/configure, including the workstation taint/label
  tasks (`roles/k3s/tasks/worker.yml`), plus etcd_backup.
- `known_hosts` — refresh node host keys in `~/.ssh/known_hosts` and
  `/etc/ssh/ssh_known_hosts` (`known_hosts_files`). The sandbox relies on
  the `/etc` copy; it can't write `/etc`, so this tag must run from a
  devcontainer terminal (`postCreate.sh` runs it on every rebuild).

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
  -o jsonpath='{.spec.source.targetRevision}'
```

If it's not `main`, **stop and ask the user** whether to:
(a) merge the tracked branch to main first, then branch off main, or
(b) base the new work on the currently-tracked branch.

## Topology rules

### Multi-homed nodes
K3s auto-detects the node IP from the default route, which may be the
wrong subnet. Set `node_ip` in `hosts.yml` for any node with multiple
NICs — Cilium tunnels to the node's advertised address, so otherwise
pod networking to it silently breaks.

### Cilium is the CNI (ADR 0015)
No flannel, kube-proxy or k3s policy controller. The `k3s` role installs
Cilium once (`roles/k3s/tasks/cilium.yml`, from the ArgoCD Application
`kubernetes-services/templates/cilium.yaml`, which must stay plain YAML:
no `{{ }}`), then ArgoCD owns it. Never `helm upgrade` it by hand. The
role refuses to switch a live flannel server to Cilium: that is a
rebuild. Debug with `kubectl -n kube-system exec ds/cilium -c
cilium-agent -- cilium-dbg status` and `hubble observe`.

### Control-plane `NoSchedule` taint
The control plane (e.g. node02) is tainted `NoSchedule`. DaemonSets
without a matching toleration won't schedule there, so it can safely
be skipped when running `--tags servers` for node-level drivers (DRA
plugins, etc.).

### Standby control-plane `PreferNoSchedule` taint
`standby_control_plane` in `group_vars/all.yml` (e.g. node03) names the
recovery target for `docs/how-to/recover-control-plane.md`. The `cluster`
tag taints it `node-role.kubernetes.io/standby-control-plane:PreferNoSchedule`
(soft: the scheduler avoids it but can still use it) and strips that taint
from any other node. When the standby is promoted, set `control_plane` to
it and repoint `standby_control_plane` at the next spare (or empty it);
`--tags cluster` then sets `NoSchedule` and moves the soft taint. Don't pin
a `local-nvme` PV to the standby. Use `kubernetes.core.k8s_taint` for node
taints, not a `k8s` patch of `spec.taints`, which replaces the whole list.

### Workstation taint (ws03)
Workstation nodes carry `workstation=true:NoSchedule` because they may
reboot unexpectedly. This has these consequences you must design for:

- **DaemonSets that need ws03** must tolerate the taint. The
  `nvidia-device-plugin` template already does; audit any new DaemonSet
  that needs to run there.
- **Monitoring workloads stay off workstations.** node-exporter tolerates
  every taint so it can report workstation metrics; Grafana and Prometheus
  tolerate the workstation taint but are pinned to their nodes by their
  `local-nvme` PVs. Alertmanager, the Prometheus operator and
  kube-state-metrics do not tolerate it. Don't add the toleration to
  anything that must survive a workstation reboot.
- **No automatic maintenance on workstations**: kured and the k3s
  upgrade Plans skip them, and `update_packages` leaves their
  unattended-upgrades config alone and never reboots them.
- **amd64-only workloads land on the untainted amd64 workers** (e.g. nuc2,
  nuc1); ws03's taint keeps them off it. A chart with
  `nodeSelector: kubernetes.io/arch: amd64` can land on any of them, so add
  a `kubernetes.io/hostname` selector if one node is required.

### Storage placement
There is no replicated block storage (Longhorn was dropped, ADR 0012):
- **RWO `local-nvme`**: static PVs in `additions/local-storage/`, each
  with `spec.nodeAffinity` pinning its pod (prometheus→node04,
  grafana→node04; jellyfin and scrap's off-NAS backup copy→nuc2). A new workload gets its own PV and node, never
  ws03. Losing the node takes the workload offline until it's back.
- **Shared volumes**: `nfs-stable` is the default StorageClass (one fixed
  NAS folder per PVC, so a rebuild gets the data back). `nfs-rwx` is a
  scratch class, only when named: its folder is deleted with the PVC.

## BMC power operations

When a node is `NotReady` and SSH times out, `ansible -m reboot` and the
graceful procedures in `docs/how-to/node-operations.md` cannot help —
both the kubelet and `sshd` on the node are gone. Power-cycle via the
Turing Pi BMC instead.

The BMC is reachable as `{{ tpi_user }}@turingpi` (default `root@turingpi`,
defined in `group_vars/all.yml`). Each slot maps to a node via
`slot_num` in `hosts.yml`: node02→2, node03→3, node04→4 (slot 1 is not
used by the cluster).
`nuc1`, `nuc2` and `ws03` are not on the BMC.

```bash
# What the BMC thinks of all four slots
ssh root@turingpi 'tpi power status'

# Power-cycle a single node (off → wait → on) — the form used by roles/flash
ssh root@turingpi 'tpi power off -n 4 && sleep 15 && tpi power on -n 4'
```

Notes:
- Don't try `kubectl drain` first — the node is unreachable, so the
  drain will just hang. Just power-cycle and let workloads reschedule
  (or come back, for DaemonSets pinned to that node).
- Hard power-cycle is unclean for in-flight writes. If the node hosts
  live local-PV data (see CLAUDE.md "Local PV data paths are sacred":
  Prometheus and Grafana on node04),
  expect fsck on boot — check pod logs once the node returns.
- For the Claude sandbox specifically: the BMC SSH key isn't reachable
  from the sandbox (the `--clearenv` bwrap wrapper strips `SSH_AUTH_SOCK`,
  and the Claude key is only authorised on the `ansible` account). The `!`
  prompt prefix runs inside the same sandbox, so it doesn't help — ask
  the user to run `ssh root@turingpi 'tpi power ...'` from a regular
  devcontainer terminal or the host shell.

## k3s version

`k3s_minor` (group_vars) is read from `k3s.minor` in
`kubernetes-services/values.yaml`; the control plane installs from that
release channel, workers join at the control plane's running version, and
system-upgrade-controller applies patches nightly. Edit the value in
`values.yaml`, never in group_vars. `-e k3s_version=v1.34.6+k3s1` still
pins an exact release, but only on the `k3s_minor` line. See
`docs/how-to/upgrade-k3s.md`.

## Foot-guns

- **`k3s_api_name` must resolve before the `k3s` tag** — agents join,
  and the kubeconfig points at, `https://<k3s_api_name>:6443` (e.g.
  `k3s.lan`, a router DNS record), not the control plane's IP. The role
  asserts it resolves to `control_plane` on every node and the
  controller (warns only under `--check`). Moving the control plane =
  change `control_plane` + push the router template (`just router-dhcp`,
  which points the record at `control_plane`'s `lan_ip`); in an emergency
  `just k3s-api-dns <ip>` repoints it via uci, then `just router-dhcp` once
  `control_plane` is updated, or the next push resets it; see
  `docs/how-to/recover-control-plane.md`.
- **`known_hosts` write tasks need `throttle: 1`** — parallel writes
  race on the shared file. The scans run in parallel; don't add `serial`.
- **Traefik is disabled** — `--disable=traefik`; Cilium's Gateway API
  serves every app (ADR 0016). Do not assume Traefik CRDs exist, nor an
  IngressClass: there is no Ingress controller.
- **No automated tests** — validate by running playbook tags against
  the live cluster.
- **Ansible `k8s` module merges annotations** — it never removes
  annotations that were previously set on an object it applies. If you
  remove annotations from a template, the object must be deleted (a
  `state: absent` task, as for the old ArgoCD Ingress in
  `roles/cluster/tasks/argocd.yml`) and re-created by the playbook.
- **ArgoCD `valuesObject` overrides `values.yaml`** — for child
  apps, the image tag is set in `templates/*.yaml`
  under `valuesObject`, not in `additions/*/values.yaml`. Editing
  `values.yaml` alone has no effect — check the template first.
- **`admin_emails` is duplicated** — must be kept in sync between
  `kubernetes-services/values.yaml` (Helm) and `group_vars/all.yml`
  (Ansible). After changing the Ansible copy, re-run `--tags cluster`.
- **Decommission before ArgoCD** — when tearing down the cluster, the
  decommission playbook deletes ArgoCD Applications (orphan cascade)
  *before* scaling down workloads. Doing it in the other order means
  ArgoCD reconciliation re-creates pods faster than you can remove
  them.
- **`gh pr edit` fails on this repo** — classic projects warning
  causes a GraphQL error. Use
  `gh api repos/OWNER/REPO/pulls/N -X PATCH -f body=...` instead.
- **`local-nvme` PVs get stuck `Released` after ArgoCD app delete**
  — chart-generated PVCs (StatefulSet `volumeClaimTemplates`) are
  owned by the consuming ArgoCD app, so `argocd app delete` cascades
  to the PVC via `resources-finalizer.argocd.argoproj.io`. The
  static PV (`Retain` policy, pre-bound via `claimRef`) keeps the
  **dead PVC's `uid`** in `spec.claimRef.uid`. New PVCs get fresh
  UIDs and can't bind → pod `Pending`, scheduler reports `didn't
  find available persistent volumes to bind`. Fix:
  `kubectl patch pv <name> --type=json -p '[{"op":"remove","path":"/spec/claimRef/uid"},{"op":"remove","path":"/spec/claimRef/resourceVersion"}]'`.
  (This is the rare authorised exception to the no-mutate-ArgoCD-
  managed rule — you're clearing kube-managed runtime state, not
  changing template intent.) Long-term fix tracked in issue #397.
  Don't `argocd app delete`/recreate the `local-nvme`-backed apps
  (grafana, prometheus, jellyfin, scrap). To re-pin a PV to another node, follow
  `docs/how-to/node-operations.md` ("Move a local-nvme PV"):
  `argocd app delete-resource local-storage --core --kind
  PersistentVolume --resource-name <pv>`, then `argocd app sync
  local-storage --core`, with the kube context namespace `argo-cd`.
  `argocd app sync --replace` is refused: the server disables it.

## Key files
- `pb_all.yml` — main playbook
- `pb_decommission.yml` — teardown
- `group_vars/all.yml` — all variables
- `hosts.yml` — inventory with node vars
- `roles/` — Ansible roles
