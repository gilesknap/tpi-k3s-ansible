#!/bin/bash
set -euo pipefail

# Wipe any credential helpers and SSH URL rewrites injected by VS Code's
# Dev Containers extension when it copies the host gitconfig. An empty-string
# value resets the helper list so only an explicit PAT via `gh auth login`
# can authenticate to remotes.
git config --global credential.helper ''

# Remove any URL rewrites copied from the host gitconfig (e.g. HTTPS→SSH
# mappings for github.com). Inside the container we authenticate with a gh
# PAT over HTTPS, so SSH rewrites break git push/pull.
git config --global --remove-section url.ssh://git@github.com/ 2>/dev/null || true
git config --global --remove-section url.git@github.com: 2>/dev/null || true

# Rewrite SSH remote URLs to HTTPS so the gh-managed credential helper works.
git config --global url.https://github.com/.insteadOf git@github.com:

# If gh CLI has cached credentials (survive container rebuild), re-register
# its git credential helper so HTTPS remotes authenticate automatically.
if gh auth status &>/dev/null; then
    gh auth setup-git
fi
