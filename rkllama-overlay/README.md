# rkllama-overlay

Thin container overlay on top of [`ghcr.io/notpunchnox/rkllama`](https://github.com/NotPunchnox/rkllama).
Applies in-tree patches at image build time and republishes to
`ghcr.io/<owner>/rkllama-overlay`. The cluster DaemonSet
(`kubernetes-services/additions/rkllama`) consumes this image instead
of upstream.

The overlay exists so we can ship targeted fixes without forking the
project. Each patch in `patches/` is a unified diff against upstream's
working tree (run with `patch -p1` from `/opt/rkllama` inside the
image). Patches are applied in lexical order, so a numeric prefix
controls sequence.

## Current patches

- **`01-clearer-error.patch`** — Replaces the misleading "file may be
  corrupted" error returned when an RKLLM load fails. The original
  wording points at the model file as the likely culprit; the real
  most-common cause on RK3588 is NPU memory contention (one RKLLM at
  a time). The new wording names that.
- **`02-auto-evict-rkllm.patch`** — Before loading a second RKLLM
  worker, evict any incumbent. Upstream's existing eviction logic
  only triggers on low system RAM, so it never fires for the NPU
  case. Result: Open-WebUI model switching now works without manual
  `rkllama_client unload`.

## Bumping the upstream base

1. Resolve the current `:main` digest (see the comment block at the
   top of `Dockerfile` for a copy-pasteable one-liner).
2. Update the `FROM` line in `Dockerfile`.
3. Re-grep upstream for the patch insertion points and regenerate any
   patch whose anchors have shifted. `patch --dry-run` is a quick
   verifier locally; CI builds will fail loudly if a patch no longer
   applies.

## Publishing

A new image is built and pushed on every change under
`rkllama-overlay/**` by `.github/workflows/rkllama-overlay.yml`.
Tags: `latest` (main), `beta` (branches/PRs), and `sha-<short>` for
both.

The cluster pins to a specific `sha-<short>` via
`kubernetes-services/values.yaml` so deploys are reproducible — see
`.claude/skills/rkllama/SKILL.md` for the wider operations context.
