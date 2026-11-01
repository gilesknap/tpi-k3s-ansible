# scrap secrets

This directory is a small Helm chart holding these things for scrap:

- `templates/mcp-ingress.yaml`: (only when `mcp_ingress_enabled` is true; enable
  it only with a scrap chart release that supports `SCRAP_MCP_TOKEN`) an Ingress for `scrap.<domain>/mcp` only, without the
  oauth2-proxy annotations (the main PWA Ingress comes from `additions/ingress`).
- the SealedSecret below.
- for public pages: `templates/public-namespace.yaml`, the `scrap-public`
  namespace (Pod Security `restricted`), and the upload token SealedSecret
  `scrap-publish` sealed once for each namespace (below).

This chart's `templates/` must contain a SealedSecret `scrap-secret.yaml` that unseals to a Secret named
`scrap-secrets` in the `scrap` namespace with the key `ANTHROPIC_API_KEY`.

```bash
read -rs KEY && printf %s "$KEY" | kubectl create secret generic scrap-secrets \
  --namespace scrap --from-file=ANTHROPIC_API_KEY=/dev/stdin \
  --dry-run=client -o yaml | \
kubeseal --controller-name sealed-secrets --controller-namespace kube-system -o yaml > \
  templates/scrap-secret.yaml; unset KEY
```

Run it from this directory. Do this before the first Argo sync, otherwise the pod stays in
`CreateContainerConfigError`. Commit the sealed file (see `/sealed-secrets` and docs/how-to/manage-sealed-secrets.md).

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
