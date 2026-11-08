# Upgrade K3s

K3s patch releases are applied automatically overnight by
system-upgrade-controller; see {doc}`/explanations/upgrade-model`. This page
covers what stays manual: minor upgrades, workstation nodes and checking
progress.

## Check versions and upgrade progress

```bash
kubectl get nodes                       # VERSION column per node
kubectl -n system-upgrade get plans     # target version per plan
kubectl -n system-upgrade get jobs      # one Job per node being upgraded
```

The control plane's Job usually shows two pods: the first is lost when k3s
restarts under it, and the second completes the Job. Only the first takes a
`pre-upgrade-*` snapshot; see
{doc}`/explanations/upgrade-model` for why, and which snapshot to use if
there are two.

## Upgrade to a new minor version

The cluster follows one k3s minor line, set by `k3s.minor` in
`kubernetes-services/values.yaml` (e.g. `v1.34`). Both the upgrade Plans and
the Ansible `k3s` role read it.

1. Check the [k3s release notes](https://docs.k3s.io/release-notes/v1.35.X)
   for the new minor. Move one minor at a time (Kubernetes does not support
   skipping minors).
2. Change `k3s.minor` (e.g. `v1.34` → `v1.35`), commit and merge to `main`.
3. ArgoCD updates the Plans. In the next upgrade window the control plane
   is snapshotted and upgraded, then the workers one at a time.
4. Upgrade workstation nodes by hand (below).

To upgrade outside the window, edit `k3s.upgrade_window` in the same file.

## Upgrade a workstation node

Workstation nodes (`workstation: true` in the inventory) are excluded from
automatic upgrades. Upgrade them after the rest of the cluster, when the
workstation can be interrupted. For example, for a workstation named `ws03`:

```bash
just upgrade-workstation ws03
```

:::{important}
Run this in the project's devcontainer terminal (for instance the
devcontainer running on the workstation itself), where your SSH key reaches
`ansible@<node>` and `kubectl` works. It does not work on the workstation
host, which has no Ansible, or from the claude-sandbox, which deliberately
cannot SSH to its own host. The script checks SSH first and stops with a
message if it cannot connect.
:::

The script:

1. Refuses a node that is not `workstation: true` in the inventory.
2. Shows the node's k3s version and the control plane's.
3. Drains the node if it is Ready; a NotReady node is not drained (the
   playbook deletes it and lets it rejoin).
4. Runs `ansible-playbook pb_all.yml --limit <node> --tags known_hosts,k3s
   -e k3s_force=true`, which reinstalls the K3s agent at the version the
   control plane runs. Extra arguments are passed on to `ansible-playbook`,
   e.g. `just upgrade-workstation ws03 -K` to prompt for a sudo password.
5. Waits for the node to be Ready again, uncordons it, and prints the node
   and its taints (the `workstation=true:NoSchedule` taint is reapplied).

Done by hand, the core steps are below. Run them one at a time and stop
if one fails; unlike the script, they do not skip the drain for a NotReady
node or wait for the node to be Ready before uncordoning it:

```bash
kubectl drain ws03 --ignore-daemonsets --delete-emptydir-data
ansible-playbook pb_all.yml --tags known_hosts,k3s --limit ws03 -e k3s_force=true
kubectl uncordon ws03
```

A workstation's agent lags behind the automatic upgrades until you run
this. That does not block cluster upgrades: Kubernetes supports kubelets up
to three minor versions older than the API server, so the control plane and
the other workers can move ahead. Upgrade the workstation before it falls
that far behind.

## Fresh installs and Ansible re-runs

The `k3s` role installs the control plane from the `k3s.minor` release
channel, which always serves its newest patch. A worker joins at the
version the control plane runs, so an agent is never ahead of the server;
system-upgrade-controller moves every node to the newest patch in the next
window. Re-runs leave an installed node alone (only `k3s_force=true`
reinstalls).

To install a particular patch, pass it explicitly, e.g.
`-e k3s_version=v1.34.6+k3s1`; it must be on the `k3s.minor` line. The role
fails if a node already runs a newer minor than `k3s.minor`; raise
`k3s.minor` instead of downgrading.

:::{warning}
`k3s_force=true` on the control plane uninstalls K3s, including its etcd
data. Only use it there as part of a rebuild.
:::
