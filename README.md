[![Documentation](https://img.shields.io/badge/docs-online-blue)](https://gilesknap.github.io/tpi-k3s-ansible/)
[![License](https://img.shields.io/badge/license-Apache%202.0-green)](https://github.com/gilesknap/tpi-k3s-ansible/blob/main/LICENSE)

# gkcluster K3s homelab

This repository is one real cluster: the six-node [K3s](https://k3s.io/)
homelab behind `gkcluster.org`, and the manual its owner operates it by.
[Ansible](https://docs.ansible.com/) provisions the machines,
[ArgoCD](https://argo-cd.readthedocs.io/) delivers everything that runs on
them from this repository, and [Claude Code](https://claude.com/claude-code)
does much of the day-to-day work from a sandbox. It is published as a worked
example of a cluster run that way. It is not a turnkey template: the node
names, addresses, NAS paths and domain in it are this site's.

Source          | <https://github.com/gilesknap/tpi-k3s-ansible>
:---:           | :---:
Documentation   | <https://gilesknap.github.io/tpi-k3s-ansible>

## The cluster at a glance

| Node | Hardware | CPU / RAM | Role |
|------|----------|-----------|------|
| `node02` | Turing RK1 (arm64) on a [Turing Pi](https://turingpi.com/) 2.5 | 8 / 8 GB | Control plane and etcd; runs no workloads |
| `node03` | Turing RK1 (arm64) | 8 / 8 GB | Worker, kept light as the warm-standby control plane |
| `node04` | Turing RK1 (arm64) | 8 / 32 GB | Worker; holds the Prometheus and Grafana volumes |
| `nuc1` | Intel NUC (amd64) | 12 / 32 GB | Worker |
| `nuc2` | Intel NUC (amd64), Iris Xe graphics | 8 / 64 GB | Worker; holds Jellyfin and every Minecraft world |
| `ws03` | Desktop workstation (amd64), NVIDIA GPU | 16 / 32 GB | The owner's desktop: tainted so only pods that tolerate it land there, and never rebooted by automation |

Around the nodes:

- **The NAS.** A QNAP running Ubuntu Server and ZFS, that serves
  application data and backups over NFS. Ansible manages it but never
  destroys data: no task destroys a pool, dataset or snapshot (`just check`
  fails on the destructive commands and modules it knows, though not on one
  built from variables at run time; the nightly copy may roll back its own
  replica on the backup pool, by design), pool creation is opt-in and
  refuses an existing pool, the cluster playbooks never touch the NAS, and
  ZFS snapshots plus age-encrypted off-site backups cover the rest.
- **Cloudflare.** DNS, a Cloudflare Tunnel that carries every web hostname,
  and Cloudflare Access as a login wall in front of all but the two that are
  public on purpose. It is managed as OpenTofu code in `cloudflare/`, and
  nothing listens on the home's public address.
- **A VPS relay.** Publishes the Minecraft game ports, which a Cloudflare
  Tunnel cannot carry. The cluster dials out to it over the tailnet; the VPS
  never connects into the home network.

## What runs on it

**Platform.** ingress-nginx, cert-manager (one Let's Encrypt wildcard
certificate, by DNS-01), Sealed Secrets, oauth2-proxy and ArgoCD's Dex for
GitHub sign-in, cloudflared, the NFS CSI driver with static `local-nvme`
volumes beside it, and device plugins for the Intel and NVIDIA GPUs.

**Applications.**

- **scrap**: a personal knowledge store with an MCP endpoint. Its SQLite
  database is replicated to the NAS by Litestream, so the pod can start on
  any node.
- **Jellyfin**: media server on nuc2 with hardware transcoding, reached over
  the LAN and the tailnet.
- **Minecraft dashboard**: an admin UI that launches game worlds from
  backups; players connect through the VPS relay.
- **ntfy**: self-hosted push notifications; Alertmanager's alerts arrive on
  the owner's phone through it.
- **Monitoring**: Prometheus, Grafana and Alertmanager, plus Headlamp and
  argocd-monitor for looking at the cluster itself.

## How it is run

- **GitOps.** Ansible installs the OS, K3s and ArgoCD, then hands over. Every
  later change is a commit: ArgoCD syncs `kubernetes-services/` from this
  repository, and nothing is applied to the cluster by hand.
- **Self-patching.** Nodes install Ubuntu updates, take K3s patch releases
  and reboot overnight, one at a time. Renovate opens the pull requests for
  chart and image updates.
- **Backups.** Application data and the control plane's etcd are backed up
  nightly to the NAS, then uploaded to Google Drive, encrypted with
  [age](https://github.com/FiloSottile/age) to a key that is kept offline.
- **Claude Code in a sandbox.** Claude writes the changes, runs the
  playbooks and opens the pull requests from inside a jail on the owner's
  workstation: its own SSH key, a network filter that allows only the
  cluster hosts and the NAS, and hard rules in `CLAUDE.md`.

## Where to start reading

- [Architecture overview](https://gilesknap.github.io/tpi-k3s-ansible/explanations/architecture.html):
  the whole cluster on one page, with diagrams, and a page for each layer.
- [A tour of the cluster](https://gilesknap.github.io/tpi-k3s-ansible/tutorials/tour.html):
  a twenty-minute read-only walk round the running system.
- [Build the cluster from bare metal](https://gilesknap.github.io/tpi-k3s-ansible/tutorials/build-the-cluster.html):
  every step from powered-off hardware to the running cluster.
- [Lessons learned using Claude Code for infrastructure](https://gilesknap.github.io/tpi-k3s-ansible/explanations/claude-code-capability.html):
  the part most likely to carry over to another project.

## Borrowing from this repo

Nothing here is meant to be forked and run as it stands. The roles, charts
and scripts are written for these machines, and every `SealedSecret` can
only be decrypted by this cluster. The ideas travel better than the files:
the split between Ansible and ArgoCD, the static volumes with backups to a
NAS, Cloudflare as code, and the guardrails around Claude Code. The build
tutorial ends with a list of
[what is specific to this site](https://gilesknap.github.io/tpi-k3s-ansible/tutorials/build-the-cluster.html#adapting-this-to-other-hardware)
for anyone lifting a piece of it.

<!-- README only content. Anything below this line won't be included in index.md -->

See <https://gilesknap.github.io/tpi-k3s-ansible> for full documentation.
