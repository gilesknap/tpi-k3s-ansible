# 5. Taint ws03 as Workstation Node

**Status:** Accepted (deferred application)

## Context

ws03 is a workstation that may reboot for updates or user activity. Only GPU
workloads and monitoring should run there intentionally. General pods should
prefer the always-on RK1 nodes.

## Decision

Apply `workstation=true:NoSchedule` taint driven by `workstation: true` in
hosts.yml. Add tolerations to llamacpp (GPU workload), monitoring (grafana,
prometheus, alertmanager), and supabase (x86-only).

## Consequences

- General pods automatically avoid ws03
- Intentional workloads explicitly opt in via tolerations
- Taint application deferred until nuc2 (second x86 node) is added to cluster
- Code committed and ready — just run `--tags servers` when nuc2 is online
