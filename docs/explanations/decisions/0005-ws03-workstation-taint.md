# 5. Taint Workstation Nodes

**Status:** Accepted (applied)

## Context

Nodes marked `workstation: true` in the inventory are machines that may reboot
for desktop updates or user activity. Only GPU workloads and monitoring should
run there intentionally. General pods should prefer always-on nodes.

*Example: in the author's cluster, ws03 is a desktop workstation with an
NVIDIA GPU that doubles as a K3s worker.*

## Decision

Apply `workstation=true:NoSchedule` taint driven by `workstation: true` in
hosts.yml. Add tolerations to GPU workloads (llamacpp) and monitoring
(grafana, prometheus, alertmanager). Other services should not tolerate the
taint — they belong on dedicated, always-on worker nodes.

## Consequences

- General pods automatically avoid workstation nodes
- Intentional workloads explicitly opt in via tolerations
- x86-only services (e.g. Supabase) should run on dedicated x86 workers, not
  workstations — add a second x86 node before applying the taint
- Longhorn storage excluded from workstations (see ADR 0009)
