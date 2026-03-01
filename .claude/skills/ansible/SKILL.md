---
name: ansible
description: Ansible roles, playbook conventions, inventory structure, force flags, and idempotency patterns
---

# Ansible Conventions

## Roles and Tags

| Role | Purpose | Tag |
|------|---------|-----|
| `roles/update_packages` | OS packages on all nodes | `servers` |
| `roles/tools` | CLI tools (helm, kubectl, kubeseal) | `tools` |
| `roles/k3s` | K3s installation and config | `k3s` |
| `roles/cluster` | ArgoCD bootstrap and cluster setup | `cluster` |

**The tag for packages is `servers`, NOT `update_packages`.** The latter silently does nothing.

```bash
# All nodes
ansible-playbook pb_all.yml --tags servers
# Specific nodes
ansible-playbook pb_all.yml --tags servers --limit node02,node03
```

## Force Flags

All default to `false` — set to `true` only when explicitly needed:
- `do_flash` — re-flash node firmware
- `k3s_force` — force K3s reinstall
- `cluster_force` — force ArgoCD re-bootstrap

## Idempotency Patterns

Use `creates:`, `when:`, `stat` checks, or task registration to ensure idempotent tasks.

## Inventory Conventions

- Node groups: `<bmc_hostname>_nodes` (e.g. `turingpi_nodes` for BMC host `turingpi`)
- Per-node vars: `slot_num` (1-4), `type` (`rk1`/`pi4`), `root_dev` (NVMe target)
- Groups: `all_nodes` = all Turing Pi groups + `extra_nodes`
- Reference: `docs/reference/inventory.md`

## Style

- 2-space indent, sentence-case task names
- Lint with `ansible-lint`; suppress with `# noqa <rule>`
- All config changes go in roles, never ad-hoc commands

## Reference Docs

- `docs/reference/playbook-tags.md`
- `docs/reference/variables.md`
- `docs/reference/inventory.md`
