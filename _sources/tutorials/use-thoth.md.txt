# Use the thoth PKM

:::{important}
**This tutorial is specific to the author's thoth instance.** It uses the
real URLs of this cluster's deployment:

- MCP endpoint: `https://thoth.gkcluster.org/mcp`
- PKM vault repo: `https://github.com/gilesknap/pkm-vault-demo.git`

If you are connecting to **someone else's** thoth installation, replace
both of these with the URLs they give you. Everything else in the steps
is identical.
:::

This is the **user** side of thoth: how to read, edit, and search a thoth
PKM vault once an administrator has it running. It does not cover deploying
or operating the server — that is {doc}`/how-to/thoth`. It sticks to the
minimum needed to actually use the tool day to day.

A thoth PKM has two faces:

- **A Git repo of Markdown notes** (the *vault*). You read and edit it
  locally in Obsidian; changes sync back over Git.
- **An MCP server** that lets Claude Code and Claude.ai search and capture
  into the same vault using `pkm_*` tools.

## Prerequisites

- A GitHub account that the thoth admin has **added to the vault repo** (so
  you can clone and push) and to thoth's **OAuth allowlist** (so the MCP
  tools admit you). Without the allowlist, OAuth succeeds but tool calls
  return 403.
- [Obsidian](https://obsidian.md/) installed.
- [Claude Code](https://claude.com/claude-code) and/or a
  [claude.ai](https://claude.ai/) account, depending on which clients you
  want.

## 1 -- Clone the vault

Clone the vault repo to a local folder. This folder becomes your Obsidian
vault.

```bash
git clone https://github.com/gilesknap/pkm-vault-demo.git ~/pkm-vault
```

## 2 -- Open the vault in Obsidian

1. Launch Obsidian and choose **Open folder as vault**.
2. Select the folder you just cloned (`~/pkm-vault`).

You can now read and edit the notes. To keep them in sync with the repo
(and with whatever thoth and other users capture), add the Git plugin.

### Add the Obsidian Git plugin

1. **Settings → Community plugins → Turn on community plugins**.
2. **Browse**, search for **Obsidian Git**, **Install**, then **Enable**.
3. In the plugin's settings, set an auto-sync interval (e.g. **Vault backup
   interval** = 10 minutes) so edits are committed and pushed, and remote
   changes are pulled, automatically.

Obsidian Git uses your existing Git credentials for the repo. If pushes are
rejected, confirm the admin has given your GitHub account write access to
the vault repo.

## 3 -- Connect Claude Code

Register the MCP server once:

```bash
claude mcp add --transport http thoth https://thoth.gkcluster.org/mcp
```

The first session that connects opens a browser for GitHub consent. Approve
it with the GitHub account that is on the allowlist; the token is cached for
later sessions. Then, in a session:

```
/mcp
```

lists thoth's `pkm_*` tools. To re-authorize later, `claude mcp remove thoth`
and add it again.

## 4 -- Connect Claude.ai

1. Open [claude.ai](https://claude.ai/) and go to a **Project** (or create
   one).
2. Open **Project settings → Connectors** (called **Integrations** in some
   versions of the UI).
3. **Add custom integration** and enter the URL
   `https://thoth.gkcluster.org/mcp`.
4. Claude.ai redirects you to GitHub to authorize. After consent, thoth's
   `pkm_*` tools appear in the project.

## Verify

In a fresh Claude Code session or claude.ai Project conversation:

1. Ask Claude to list its tools — the `pkm_*` tools should appear.
2. Ask it to run a read-only `pkm_*` tool (a search or stats tool) and
   confirm it returns results rather than an auth error.
3. Capture a note and confirm it lands as a new Markdown file in the vault
   (it will appear in Obsidian after the next Git sync).

## See also

- {doc}`/how-to/connect-thoth-mcp` — the MCP OAuth flow in depth, plus
  troubleshooting for auth loops and vanished tools.
- {doc}`/how-to/thoth` — deploying and operating a thoth server (admin side).
