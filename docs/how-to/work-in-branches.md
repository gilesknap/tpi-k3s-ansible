# Work in Branches and Forks

ArgoCD tracks a specific Git branch for all cluster services. When developing in
a feature branch or a fork, you can switch the cluster to track any branch
without pushing changes to that branch first.

## How branch propagation works

The root `all-cluster-services` ArgoCD Application is created by Ansible from
`argo-cd/argo-git-repository.yaml`. It sets `targetRevision` to the value of
`repo_branch` in `group_vars/all.yml` and passes it down to all child apps via
`valuesObject`. Child app templates use `{{ .Values.repo_branch }}` for their
own `targetRevision`.

This means `group_vars/all.yml` is the **single source of truth** for which
branch the entire cluster tracks.

## Working in a feature branch

### Step 1: Update `group_vars/all.yml`

```yaml
repo_branch: my-feature-branch
```

### Step 2: Apply with the cluster tag

```bash
ansible-playbook pb_all.yml --tags cluster
```

This updates the root ArgoCD Application's `targetRevision` and passes the new
branch to all child apps. No commit or push is needed — the playbook applies
directly to the cluster.

For a one-off switch without editing the file:

```bash
ansible-playbook pb_all.yml --tags cluster -e repo_branch=my-feature-branch
```

### Step 3: Return to main

```bash
ansible-playbook pb_all.yml --tags cluster -e repo_branch=main
```

(Or edit `group_vars/all.yml` back to `main` and re-run.)

## Working in a fork

If you forked the repository, update the remote URL in `group_vars/all.yml`:

```yaml
repo_remote: https://github.com/your-user/tpi-k3s-ansible.git
```

Then deploy:

```bash
ansible-playbook pb_all.yml --tags cluster
```

For a one-off deployment from a fork without changing the config file:

```bash
ansible-playbook pb_all.yml --tags cluster \
  -e repo_branch=your_branch \
  -e repo_remote=https://github.com/your-user/tpi-k3s-ansible.git
```
