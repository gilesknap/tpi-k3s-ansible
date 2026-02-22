# Work in Branches and Forks

ArgoCD tracks a specific Git branch for all cluster services. When developing in
a feature branch or a fork, you need to ensure ArgoCD syncs the correct branch.

## How branch propagation works

The root `all-cluster-services` ArgoCD Application deploys the
`kubernetes-services/` Helm chart. This chart's `values.yaml` contains:

```yaml
repo_branch: main
```

This value is passed to all child Applications as `{{ .Values.repo_branch }}`, which
they use as their `targetRevision`. Since ArgoCD checks out `values.yaml` at the
**same** `targetRevision` as the root app, the value is self-referential — whatever
branch ArgoCD is tracking, it reads the `repo_branch` from that branch's own
`values.yaml`.

## Working in a feature branch

### Step 1: Update `values.yaml` in your branch

Edit `kubernetes-services/values.yaml` on your branch:

```yaml
repo_branch: my-feature-branch
```

Commit and push this change.

### Step 2: Redeploy with the branch name

```bash
ansible-playbook pb_all.yml --tags cluster -e repo_branch=my-feature-branch
```

This updates the root ArgoCD Application's `targetRevision` to your branch.

### Step 3: Return to main

When done, switch the root app back to `main`:

```bash
ansible-playbook pb_all.yml --tags cluster -e repo_branch=main
```

And make sure `kubernetes-services/values.yaml` on `main` still says `repo_branch: main`.

## Working in a fork

If you forked the repository, permanently update the remote URL in `group_vars/all.yml`:

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

## Fixing stale `repo_branch` in the live Application

If you change the root Application's `targetRevision` but the child apps still track
an old branch, the live Application CR may have an old `repo_branch` baked into its
`valuesObject` that overrides `values.yaml`. Remove it:

```bash
kubectl patch application all-cluster-services -n argo-cd --type json \
  -p '[{"op":"remove","path":"/spec/source/helm/valuesObject/repo_branch"}]'
```

:::{important}
Each branch **must** have the correct `repo_branch` value in its own
`kubernetes-services/values.yaml`. If they disagree, child apps may track the wrong
branch.
:::
