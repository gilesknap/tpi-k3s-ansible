# scrap secrets

This directory is a small Helm chart holding two things for scrap:

- `templates/mcp-ingress.yaml`: (only when `mcp_ingress_enabled` is true; enable
  it only with a scrap chart release that supports `SCRAP_MCP_TOKEN`) an Ingress for `scrap.<domain>/mcp` only, without the
  oauth2-proxy annotations (the main PWA Ingress comes from `additions/ingress`).
- the SealedSecret below.

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
