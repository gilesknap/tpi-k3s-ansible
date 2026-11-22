# scrap secrets

This directory is a small Helm chart holding these things for scrap:

- `templates/mcp-ingress.yaml`: (only when `mcp_ingress_enabled` is true; enable
  it only with a scrap chart release that supports `SCRAP_MCP_TOKEN`) an Ingress for `scrap.<domain>/mcp` only, without the
  oauth2-proxy annotations (the main PWA Ingress comes from `additions/ingress`).
- the SealedSecret below.
- `templates/scrap-ntfy-secret.yaml`: the SealedSecret `scrap-ntfy`, scrap's
  ntfy token and `SCRAP_NOTIFY_URL` (key `url`). Not sealed by hand:
  `just seal-ntfy` and the rebuild seal it with ntfy's `ntfy-auth`
  (docs/how-to/ntfy.md).
- for public pages: `templates/public-namespace.yaml`, the `scrap-public`
  namespace (Pod Security `restricted`), and the upload token SealedSecret
  `scrap-publish` sealed once for each namespace (below).
- `templates/nfs-volumes.yaml`: the static NFS PVs and PVCs `scrap-data-nfs` and
  `scrap-backups-nfs` the chart uses (Litestream mode), and
  `templates/backup-copy.yaml`: the nightly copy of the newest backup off the NAS.

This chart's `templates/` must contain a SealedSecret `scrap-secret.yaml` that unseals to a Secret named
`scrap-secrets` in the `scrap` namespace with the keys `ANTHROPIC_API_KEY` (the
Claude API key for ingest), `SCRAP_MCP_TOKEN` (the main `/mcp` bearer token),
optionally `SCRAP_MCP_TOKEN_CANARY` (the claude-canary VPS's own token), and
`SCRAP_MCP_TOKENS` (the two comma separated, or the main one alone, which the
chart passes to scrap as its `SCRAP_MCP_TOKEN` variable). A rebuild seals it through `just generate-and-seal-all`. To
reseal it from the live Secret, keeping the MCP tokens every client holds:

```bash
just seal-scrap-secrets --api-key        # a new Claude API key
just seal-scrap-secrets --canary new     # a new canary token
just seal-scrap-secrets --canary revoke  # drop the canary token
```

Commit the sealed file (see `/sealed-secrets` and docs/how-to/manage-sealed-secrets.md),
and once ArgoCD has synced it restart scrap: `kubectl -n scrap rollout restart deploy/scrap`.
A first install, with no live Secret, goes through `just generate-and-seal-all`;
without the Secret the pod stays in `CreateContainerConfigError`.

## Public pages upload token

scrap (in `scrap`) and its public site's receiver (in `scrap-public`) share a
token, at least 32 characters, in a Secret `scrap-publish` with the key `token`
in **both** namespaces. SealedSecrets are bound to their namespace, so seal the
same token twice. To rotate it, run from this directory:

```bash
bash -c 'set -euo pipefail
t=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")
for ns in scrap scrap-public; do
  printf %s "$t" | kubectl create secret generic scrap-publish --namespace "$ns" \
    --from-file=token=/dev/stdin --dry-run=client -o yaml | \
  kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml \
    > "templates/$ns-publish-secret.yaml"
done'
```

Commit both files together, then restart both pods after the sync
(`kubectl -n scrap rollout restart deploy/scrap` and
`kubectl -n scrap-public rollout restart deploy/scrap-public`), since each reads
the token at start.
