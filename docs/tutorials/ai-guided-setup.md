# AI-Guided Setup

The fastest way to get a cluster running is to let Claude Code walk you through
it interactively. The `/bootstrap-cluster` command asks you a series of questions,
configures all the files, generates secrets, runs the Ansible playbooks, and
writes a credentials file — all in one conversation.

## Prerequisites

- **Claude Code** installed ([claude.ai/claude-code](https://claude.ai/claude-code))
- A **devcontainer** session open in this repository (see below)
- Your target hardware ready (Turing Pi boards **or** any modern Linux servers)

If you haven't forked and cloned the repository yet, do that first:

```{include} common-setup.md
:start-after: <!-- begin:fork-clone -->
:end-before: <!-- end:fork-clone -->
```

Then open the devcontainer:

```{include} common-setup.md
:start-after: <!-- begin:devcontainer -->
:end-before: <!-- end:devcontainer -->
```

## Run the command

Open a Claude Code session inside the devcontainer and type:

```
/bootstrap-cluster
```

Claude will guide you through:

1. **Hardware inventory** — Turing Pi slots and node types, or generic server
   hostnames
2. **Cluster personalisation** — domain name, email, GitHub fork URL
3. **Optional features** — NFS storage, OAuth, Cloudflare tunnel, Open Brain
4. **File configuration** — edits `hosts.yml`, `group_vars/all.yml`, and
   `kubernetes-services/values.yaml` based on your answers
5. **SSH key setup** — checks for an existing key or walks you through
   generating one
6. **Playbook execution** — runs the Ansible playbook to flash nodes (Turing Pi)
   or configure servers, install K3s, and deploy ArgoCD
7. **Secret generation** — creates the shared admin password, and optionally
   seals Open Brain (Supabase) credentials
8. **Credentials file** — writes everything to `/tmp/cluster-credentials.txt`
   for safekeeping

The entire process takes 15--30 minutes depending on the number of nodes and
network speed.

## What happens next

After the command completes, your cluster is running with all core services
managed by ArgoCD. Claude will print next steps, but here is a summary:

- **Pick which services to run** — see {doc}`/reference/services` for the
  quick-start configurations (LLM-only, AI memory, monitoring, full stack)
- **Access services now** via port-forward — see {doc}`/how-to/accessing-services`
- **Expose services to the internet** — follow {doc}`/how-to/cloudflare-tunnel`
- **Add GitHub OAuth** — follow {doc}`/how-to/oauth-setup`
- **Enable AI memory** — follow {doc}`/how-to/open-brain`
- **Set up the NAS share for backups** — follow {doc}`/how-to/nas-setup`

## Prefer a manual setup?

If you prefer to follow written steps rather than an interactive guide, use the
hardware-specific tutorials instead:

- {doc}`getting-started-tpi` — for Turing Pi v2.5 boards
- {doc}`getting-started-generic` — for any modern Linux servers
