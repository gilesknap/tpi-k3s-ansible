---
name: ansible
description: Ansible playbook structure, roles, tags, and operational patterns for the K3s cluster.
---

# Ansible

## Playbook Structure
- Entry point: `pb_all.yml` (NOT `site.yml`)
- Vars: `group_vars/all.yml` — single source of truth for cluster-wide settings
- Inventory: `hosts.yml`

## Common Tags
- `servers` — system packages AND workstation taint/label tasks (NOT `update_packages`!)
- `cluster` — ArgoCD root app + all child apps (branch switching, service toggles)
- `k3s` — K3s install/configure

## Operational Patterns
- **Branch switching**: edit `repo_branch` in `group_vars/all.yml`, run `--tags cluster`
  Or ad-hoc: `ansible-playbook pb_all.yml --tags cluster -e repo_branch=<branch>`
- **Adding a node**: use `/add-node` skill
- **Full bootstrap**: use `/bootstrap-cluster` skill

## Gotchas
- `known_hosts` task must run `serial: 1` — parallel writes cause race conditions
- Traefik disabled (`--disable=traefik`) — NGINX Ingress used instead
- No automated tests — validate by running playbook tags against live cluster
- Pre-commit hooks require `uv run` for git operations

## Workstation Taint (ws03)
- `hosts.yml` has `workstation: true` on ws03
- `worker.yml` has conditional taint + label tasks
- Tolerations added to: llamacpp, monitoring, supabase
- Do NOT add nodeSelector to monitoring (existing Longhorn PVs have node affinity)
- Apply only after nuc2 joins: `ansible-playbook pb_all.yml --tags servers`

## Key Files
- `pb_all.yml` — main playbook
- `group_vars/all.yml` — all variables
- `hosts.yml` — inventory with node vars
- `roles/` — Ansible roles
