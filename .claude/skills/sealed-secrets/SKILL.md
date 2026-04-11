---
name: sealed-secrets
description: Sealing, rotating, and troubleshooting SealedSecrets in the K3s cluster — file naming rules, placeholder base64 pitfalls, seal-argocd-dex subcommands, pod restart requirements after reseal.
---

# Sealed Secrets

Bitnami sealed-secrets is the only commit-safe way to ship Kubernetes
Secrets through this repo. `kubeseal` reads the live cluster's public
key and encrypts secret data into a committed `*-secret.yaml` file that
the in-cluster controller decrypts into a real `Secret`.

`kubeseal` is one of the few commands allowed to touch the live cluster
directly (see CLAUDE.md hard rules).

## File naming

- SealedSecret files **must be named `*-secret.yaml` (singular)**.
  `*-secrets.yaml` is not in the `.gitleaks.toml` allowlist — the
  pre-commit hook will block the commit with no obvious reason.

## The placeholder base64 foot-gun

**Never commit a `*-secret.yaml` with placeholder text like `REPLACE_ME`
in `encryptedData`.** The chain of silent failures is brutal:

1. Controller fails to decrypt: `illegal base64 data`
2. The real `Secret` is never created
3. Any Prometheus operator CR (Alertmanager / Prometheus) referencing
   the missing Secret via `secrets:` silently **omits the volume mount**
4. You get runtime errors that don't obviously point at the placeholder

Always seal a real value immediately, or **omit the file entirely**
until you have one. If you must stub it out, use a short real string
and reseal later — never a literal `REPLACE_ME`.

## `scripts/seal-argocd-dex` — per-secret subcommands

Running `seal-argocd-dex` bare (or with `all`) re-seals everything and
prompts for GitHub creds + Slack webhook. To rotate just one secret
without re-entering unrelated values, use a subcommand:

```
seal-argocd-dex [github|argocd|monitor|grafana|open-webui|slack]
```

Subcommands read existing keys from the running `argocd-dex-secret` to
preserve values they don't touch, so `all` must have been run at least
once before a subcommand will work.

## Pod restarts after reseal

Pods that read secret values via `envFrom` or `secretKeyRef` **cache
values at pod startup**. After re-sealing, running pods keep stale
values and OAuth/service login fails with errors like
`invalid client_secret` — even though the Kubernetes `Secret` object
itself is correct.

`seal-argocd-dex` now restarts affected pods automatically. If you
re-seal through any other path (manual `kubeseal`, rebuild playbook,
etc.), you must restart pods in these namespaces:

- `argo-cd` / `argocd-monitor` (Dex: `just restart-dex`)
- `monitoring` (`kubectl rollout restart sts grafana-prometheus -n monitoring`)
- `open-webui`
- `headlamp`

## `cookie-secret` generation

oauth2-proxy's cookie secret must be **exactly 16, 24, or 32 bytes**
for the AES cipher. Regressions have happened twice:

- `base64.b64encode(token_bytes(32))` → 44 chars → oauth2-proxy crash
- Use `secrets.token_hex(16)` (32 hex chars = 32 bytes) — this is what
  `scripts/seal-argocd-dex` does. Do **not** change it.

## Non-deterministic re-encryption

`kubeseal` adds random padding, so re-sealing the same plaintext
produces a different ciphertext each run. This is expected. Don't try
to diff-match sealed ciphertexts — diff the underlying plaintext via
the generator script or compare decrypted `Secret` contents on-cluster.

## Key files

- `scripts/seal-argocd-dex` — main Dex/OAuth sealing entry point
- `scripts/seal-from-json` — batch sealing from `/tmp/cluster-secrets/`
- `scripts/create-prometheus-admission-secret` — one-shot webhook TLS
- `kubernetes-services/additions/*/`-secret.yaml` — committed sealed secrets
