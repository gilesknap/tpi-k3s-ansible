# Upgrade K3s

K3s patch releases are applied automatically overnight by
system-upgrade-controller; see {doc}`/explanations/upgrade-model`. This page
covers what stays manual: minor upgrades, `ws03` and checking progress.

Two Plans in the `system-upgrade` namespace do the work, both following the
release channel for `k3s.minor` (`v1.34` today) and both starting only
between 01:00 and 02:00 Europe/London, any night:

| Plan | Nodes | What it does |
|------|-------|--------------|
| `k3s-server` | `node02` | Takes a `pre-upgrade-*` etcd snapshot, cordons the node and upgrades the server |
| `k3s-agent` | `node03`, `node04`, `nuc1`, `nuc2` | Waits for `k3s-server`, then drains and upgrades one worker at a time |

`ws03` is in neither.

## Check versions and upgrade progress

```bash
kubectl get nodes                       # VERSION column per node
kubectl -n system-upgrade get plans     # target version per plan
kubectl -n system-upgrade get jobs      # one Job per node being upgraded
```

The Job for `node02` usually shows two pods: the first is lost when k3s
restarts under it, and the second completes the Job. Only the first takes a
`pre-upgrade-*` snapshot; see
{doc}`/explanations/upgrade-model` for why, and which snapshot to use if
there are two.

## Upgrade to a new minor version

The cluster follows one K3s minor line, set by `k3s.minor` in
`kubernetes-services/values.yaml`. It is the only place to change: the
`system-upgrade` ArgoCD app passes it to the Plans, and Ansible reads the
same value as `k3s_minor` (`group_vars/all.yml` looks it up in
`values.yaml`), so a later install or rejoin uses the same line.

1. Check the [K3s release notes](https://docs.k3s.io/release-notes/v1.35.X)
   for the new minor. Move one minor at a time (Kubernetes does not support
   skipping minors).
2. Change `k3s.minor` (e.g. `v1.34` → `v1.35`), commit and merge to `main`.
3. ArgoCD updates the Plans. In the next upgrade window `node02` is
   snapshotted and upgraded, then the workers one at a time. The API is
   briefly unreachable while `node02` restarts K3s.
4. Upgrade `ws03` by hand (below).

To upgrade outside the window, edit `k3s.upgrade_window` in the same file
(`days`, `startTime`, `endTime`, `timeZone`), and keep it clear of the
kured window, 02:30 to 05:00.

## Upgrade ws03

`ws03` is `workstation: true` in `hosts.yml`, which excludes it from the
automatic upgrades. Upgrade it after the rest of the cluster, when the
workstation can be interrupted:

```bash
just upgrade-workstation ws03
```

:::{important}
Run this in the project's devcontainer terminal (the devcontainer runs on
`ws03` itself), where the forwarded SSH agent reaches `ansible@ws03` and
`kubectl` works. It does not work on the `ws03` host, which has no Ansible,
or from the claude-sandbox, which deliberately cannot SSH to its own host. The script checks SSH first and stops with a
message if it cannot connect.
:::

The script:

1. Refuses a node that is not `workstation: true` in the inventory.
2. Shows the node's K3s version and the one `node02` runs.
3. Drains the node if it is Ready; a NotReady node is not drained (the
   playbook deletes it and lets it rejoin).
4. Runs `ansible-playbook pb_all.yml --limit <node> --tags known_hosts,k3s
   -e k3s_force=true`, which reinstalls the K3s agent at the version
   `node02` runs. Extra arguments are passed on to `ansible-playbook`,
   e.g. `just upgrade-workstation ws03 -K` to prompt for a sudo password.
5. Waits up to ten minutes for the node to be Ready again, uncordons it, and prints the node
   and its taints. A Ready node keeps its Node object, taint and
   label through the reinstall; a NotReady node, which the playbook deletes,
   registers again with the `workstation=true:NoSchedule` taint and
   `node-role=workstation` label already set, so no other pod lands on it
   while it rejoins.

Done by hand, the core steps are below. Run them one at a time and stop
if one fails; unlike the script, they do not skip the drain for a NotReady
node or wait for the node to be Ready before uncordoning it:

```bash
kubectl drain ws03 --ignore-daemonsets --delete-emptydir-data
ansible-playbook pb_all.yml --tags known_hosts,k3s --limit ws03 -e k3s_force=true
kubectl uncordon ws03
```

The agent on `ws03` lags behind the automatic upgrades until you run this.
That does not block cluster upgrades: Kubernetes supports kubelets up to
three minor versions older than the API server, so `node02` and the other
workers can move ahead. Upgrade `ws03` before it falls that far behind.

## Fresh installs and Ansible re-runs

The `k3s` role installs the control plane from the `k3s.minor` release
channel, which always serves its newest patch (a full rebuild,
{doc}`/tutorials/build-the-cluster`). A worker joins at the
version the control plane runs, so an agent is never ahead of the server;
system-upgrade-controller moves every node to the newest patch in the next
window. Re-runs leave an installed node alone (only `k3s_force=true`
reinstalls).

To install a particular patch, pass it explicitly, e.g.
`-e k3s_version=v1.34.6+k3s1`; it must be on the `k3s.minor` line. The role
fails if a node already runs a newer minor than `k3s.minor`; raise
`k3s.minor` instead of downgrading.

:::{warning}
`k3s_force=true` on `node02` uninstalls K3s, including its etcd data. Only
use it there as part of a rebuild ({doc}`/how-to/reflash-rebuild`).
:::
