# scrap secrets

This directory is a small Helm chart holding two things for scrap:

- `templates/mcp-ingress.yaml`: an Ingress for `scrap.<domain>/mcp` only, without the
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

Run it from this directory. Commit the sealed file (see `/sealed-secrets` and docs/how-to/manage-sealed-secrets.md).
