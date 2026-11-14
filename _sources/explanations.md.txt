# Explanations

How the cluster is put together and why. The architecture overview shows the
whole cluster on one page and leads to nine pages that take one subject each,
with diagrams: hardware, provisioning, GitOps delivery, networking,
authentication, security, storage, backups and the Claude Code integration.
The pages after it explain how the cluster keeps itself patched, what each
Ansible role does, what was learned running it with Claude Code, and the
decisions that have a longer history.

```{toctree}
:maxdepth: 1
:caption: Architecture

explanations/architecture
```

```{toctree}
:maxdepth: 1
:caption: How it runs

explanations/upgrade-model
explanations/ansible-roles
```

```{toctree}
:maxdepth: 1
:caption: Claude Code

explanations/claude-code-capability
```

```{toctree}
:maxdepth: 1
:caption: Decisions

explanations/decisions
```
