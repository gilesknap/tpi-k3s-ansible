# Set up and run Claude Code

The procedures for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
against this cluster. Claude runs inside
[claude-sandbox](https://github.com/DiamondLightSource/claude-sandbox), a
bubblewrap jail inside the devcontainer, with its own narrow set of
credentials. {doc}`/explanations/architecture/claude-code` explains that
structure and why it is built that way; this page is only what to type.

Two places come up throughout:

- the **outer devcontainer**: an ordinary VS Code terminal in the
  container. It runs as root, has the forwarded SSH agent, and can write
  `/etc`.
- the **sandbox**: where `claude` runs. It sees the workspace, `/cache`
  and a short list of paths under `/root`, and nothing else of the
  container's home directory.

## Before opening the container

Load the ansible key into a running `ssh-agent` on the workstation:

```bash
ssh-add ~/.ssh/ansible_rsa
ssh-add -l
```

VS Code forwards the agent that is running when the container starts, and
copies `~/.ssh/known_hosts` in. If no agent is running at that moment the
container has no `SSH_AUTH_SOCK`, and Ansible cannot reach the nodes until
the container is reopened.

## What the container build sets up

Nothing here needs doing by hand; it is listed so that a broken container
can be diagnosed.

| Piece | Where it comes from |
|-------|---------------------|
| claude-sandbox itself | Its VS Code extension (`diamondlightsource.claude-sandbox-vscode` in `devcontainer.json`) installs the upstream release. No sandbox code is kept in this repo |
| `--device=/dev/net/tun` | A `runArgs` entry in `devcontainer.json`. The sandbox's network jail needs it; without it `claude` refuses to start |
| `/etc/claude-sandbox.conf` | `.devcontainer/postCreate.sh` copies this repo's `.devcontainer/claude-sandbox.conf` over the installer's default |
| `kubectl`, `helm`, `kubeseal`, `argocd` | `postCreate.sh` runs `ansible-playbook pb_all.yml --tags tools`, which installs them in `/root/bin` (a volume, so they survive a rebuild) |
| Node host keys | `postCreate.sh` runs `--tags known_hosts`, which writes them to `/etc/ssh/ssh_known_hosts`, the only copy the sandbox can read |
| Git credentials | `postStart.sh` clears any credential helper and SSH rewrite copied in from the host, so that only the `gh` token below can push |

This repo's `claude-sandbox.conf` makes three changes to the sandbox's
defaults: the writable workspace is the whole of `/workspaces` (so sibling
repos can be edited); `/cache`, `/root/bin`, `/root/.kube` and
`/root/.config/claude-ssh` are bound in; and each cluster host and the NAS
is an `allow-ip`, because the sandbox otherwise blocks every private
address.

## First-time setup

In the outer devcontainer:

```bash
just setup
```

This checks that the forwarded agent has a key, then runs
`claude-sandbox gh-auth`, which asks for a GitHub token and stores it where
the sandbox can use it. Give it a fine-grained personal access token
scoped to this repository (and any sibling repo Claude should push to),
with read and write on contents and pull requests. `claude-sandbox gh-auth`
can also be run by itself. The token is kept in a volume named for the
repo (`gh-auth-tpi-k3s-ansible`), so it survives a container rebuild and is
not shared with other projects.

Then start Claude Code from the VS Code extension, or with `claude` in a
terminal.

## Give Claude its own access to the nodes

The sandbox cannot see the forwarded SSH agent, so by default Claude can
use `kubectl` but cannot SSH to a node or run a playbook. To allow that,
give it a key of its own. In the outer devcontainer:

```bash
just claude-ssh-bootstrap
```

The recipe creates an ed25519 key pair in `/root/.config/claude-ssh` if
there is none (a volume, `iac2-claude-ssh`, so it persists), then runs the
`claude_key` play of `pb_all.yml`, which adds the public key to the
`ansible` account on every node. It has to run in the outer devcontainer
because the first connection to each node uses the owner's key from the
agent.

Inside the sandbox nothing passes that key automatically, so Claude names
it each time:

```bash
ssh -i /root/.config/claude-ssh/id_ed25519 ansible@node03
ansible-playbook pb_all.yml --tags servers \
  --private-key /root/.config/claude-ssh/id_ed25519
```

To take the access away again, on every node:

```bash
just claude-ssh-bootstrap revoke
```

## After updating the sandbox

The claude-sandbox VS Code extension installs the sandbox in the outer
devcontainer and updates it (the `claude-sandbox` CLI has no update command;
`claude-sandbox install` says where it was installed from). The installer
it runs writes its own default
over `/etc/claude-sandbox.conf`, which drops this repo's `allow-ip` and
`allow-write` lines. Put them back straight afterwards:

```bash
just sandbox-conf
```

The sandbox reads the file at each launch, so start a new Claude session
for it to take effect. The same recipe applies an edit to
`.devcontainer/claude-sandbox.conf` without rebuilding the container.

## When a node is added

The sandbox reaches only the private addresses listed in
`.devcontainer/claude-sandbox.conf`. Today those are the BMC and every
host in `hosts.yml`, plus the NAS:

| Address | Host |
|---------|------|
| 192.168.1.80 | `turingpi` (BMC) |
| 192.168.1.82 to .84 | `node02` to `node04` (node02 is also the K3s API) |
| 192.168.1.91, .92 | `nuc1`, `nuc2` |
| 192.168.1.10 | `ws03` |
| 192.168.1.3 | the NAS |

When a node joins, or one changes address:

1. Add an `allow-ip = <address> # <name>` line to
   `.devcontainer/claude-sandbox.conf` and commit it.
2. `just sandbox-conf` in the outer devcontainer.
3. `ansible-playbook pb_all.yml --tags known_hosts` in the outer
   devcontainer, so the new host key reaches `/etc/ssh/ssh_known_hosts`.
4. `just claude-ssh-bootstrap`, so the new node accepts Claude's key.
5. Start a new Claude session.

If the control plane moves, check that its address is in the list: the
kubeconfig uses the name `k3s.lan`, which must resolve to an allowed
address.

## Check the sandbox

```bash
claude-sandbox verify
```

This runs the sandbox's own battery of isolation checks and prints a
`PASS` or `FAIL` line for each. It works in the outer devcontainer and
inside a session. `claude-sandbox version` reports what is installed.

## Symptoms and fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `claude` refuses to start | `/dev/net/tun` is missing from the container | Rebuild the devcontainer from this repo's `devcontainer.json` |
| `kubectl: command not found` inside the sandbox, while it works in an ordinary terminal | `/etc/claude-sandbox.conf` has lost the `allow-write = /root/bin` line, so the links in `/usr/local/bin` point at nothing. Usually after the extension has updated the sandbox | `just sandbox-conf`, then a new session |
| `kubectl` is found but has no cluster | The `/root/.kube` bind is missing (same cause), or the kubeconfig was never fetched | `just sandbox-conf`; if still empty, `ansible-playbook pb_all.yml --tags tools` in the outer devcontainer |
| A node, the API or the NAS times out from the sandbox only | Its address is not an `allow-ip` | Add it as in [When a node is added](#when-a-node-is-added) |
| `ssh ansible@<node>` says `Permission denied (publickey)` | The key was not named, or was never deployed | Add `-i /root/.config/claude-ssh/id_ed25519`; if it still fails, `just claude-ssh-bootstrap` |
| `Host key verification failed` | The node was re-flashed and `/etc/ssh/ssh_known_hosts` is stale. The sandbox cannot write `/etc` | `ansible-playbook pb_all.yml --tags known_hosts` in the outer devcontainer |
| `gh` or `git push` is not authenticated | No token, or the container was recreated without its volume | `claude-sandbox gh-auth` in the outer devcontainer |
| `apt-get` fails with a read-only filesystem | The sandbox cannot change the container | Install the package in the outer devcontainer; the sandbox sees it at once |

## Permissions

The repo commits no permission policy. `.claude/` holds only the commands
and skills below. The tool approvals a session collects are written to
`.claude/settings.local.json`, which is personal and gitignored, so one
person's allow-list never reaches a pull request. To change what is
approved, edit the `allow`, `ask` and `deny` lists under `permissions` in
that file; a pattern such as `Bash(kubectl get *)` matches any
`kubectl get` command.

The approvals are a convenience, not the safety boundary. The boundary is
the sandbox, which holds whatever a session has been allowed to run, and
the rules in `CLAUDE.md`, which Claude follows but nothing enforces.

## Commands and skills

Claude reads `CLAUDE.md` at the start of every session: the hard rules
(never change the live cluster by hand, never commit to `main`, the data
paths that must not be touched), the key paths and the conventions.

**Commands** are runbooks, started by typing their name in a session:

| Command | What it does |
|---------|--------------|
| `/rebuild-cluster` | Decommissions and rebuilds K3s and every service, keeping the data, then verifies the result and prepares the pull request |
| `/bootstrap-cluster` | The interview-driven first build of a cluster |
| `/add-node` | Adds a machine to the inventory and joins it |
| `/test-oauth-flow` | Walks each login in a browser and checks it ends where it should |
| `/pr-squash` | Regroups a branch's commits into a clean pull request |

Text after the name is passed to the command, for example
`/rebuild-cluster test PR 123 on branch my-change`.

**Skills** are background knowledge that Claude loads when a task calls
for it, or when asked by name: `/ansible`, `/argocd`, `/cloudflare`,
`/oauth` and `/sealed-secrets`. Each records the traps met in that area
(for instance, that a SealedSecret file must be named `*-secret.yaml`).

{doc}`/explanations/claude-code-capability` describes how these are used
and kept up to date.
