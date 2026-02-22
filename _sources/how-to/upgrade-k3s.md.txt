# Upgrade K3s

K3s can be upgraded by re-running the K3s installation role, which downloads and
installs the latest stable release.

## Upgrade all nodes

```bash
ansible-playbook pb_all.yml --tags k3s -e k3s_force=true
```

This uninstalls and reinstalls K3s on every node (control plane first, then workers).
The `k3s_force=true` flag forces reinstallation even if K3s is already installed.

:::{warning}
This causes a brief cluster downtime while the control plane is reinstalled. Worker
nodes will be unavailable while K3s is being reinstalled on each one.
:::

## Upgrade a single worker

```bash
ansible-playbook pb_all.yml --tags k3s --limit node03 -e k3s_force=true
```

This reinstalls K3s on only the specified worker node.

## Check current version

```bash
kubectl version
k3s --version   # Run on a node via SSH
```

## Rolling upgrade strategy

For minimal disruption:

1. Upgrade the control plane first:

   ```bash
   ansible-playbook pb_all.yml --tags k3s --limit node01 -e k3s_force=true
   ```

2. Drain and upgrade each worker one at a time:

   ```bash
   kubectl drain node02 --ignore-daemonsets --delete-emptydir-data
   ansible-playbook pb_all.yml --tags k3s --limit node02 -e k3s_force=true
   kubectl uncordon node02
   ```

3. Verify the node is Ready before proceeding to the next:

   ```bash
   kubectl get nodes
   ```

## Pin a specific K3s version

By default, the `k3s` role installs the latest stable release. To pin a version,
set the `INSTALL_K3S_VERSION` environment variable before running the install script.
Edit `roles/k3s/tasks/control.yml` and/or `roles/k3s/tasks/worker.yml` to add:

```yaml
environment:
  INSTALL_K3S_VERSION: "v1.31.5+k3s1"
```
