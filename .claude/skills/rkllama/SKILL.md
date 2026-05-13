---
name: rkllama
description: RKLLama (RK3588 NPU LLM server) operations — pod CLI quirks, model layout, hardware pinning, and the silent-failure modes of `rkllama_client pull`.
---

# RKLLama

RKLLama serves `.rkllm` models on the Rockchip RK3588 NPU. Pinned to
**node04** (a 32 GB RK1 module) via the DaemonSet's `nodeSelector`. NFS-
backed PV at `192.168.1.3:/bigdisk/k8s-cluster/models`, mounted in-pod
at `/opt/rkllama/models`.

## In-pod CLI is `rkllama_client`, not `rkllama`

The image (`ghcr.io/notpunchnox/rkllama:main`) installs the binary at
`/opt/venv/bin/rkllama_client`. A bare `rkllama` command is not on
`$PATH`. The `tools` Ansible role installs a host-side `rkllama-pull`
wrapper that hides this — but that wrapper isn't reachable from the
Claude sandbox (`--clearenv` strips the path), so direct
`kubectl exec ... rkllama_client ...` is the sandbox-friendly route.

```bash
POD=$(kubectl get pod -n rkllama -l app=rkllama -o name | head -1)
kubectl exec -n rkllama $POD -c rkllama -- /opt/venv/bin/rkllama_client list
```

## Non-interactive `pull` needs 4 path parts — silent failure otherwise

The client does `model.rsplit('/', 1)` to peel off a "custom model
name" before posting to the server. So `pull` expects:

```
owner/repo/file.rkllm/custom-name
```

If you supply only 3 parts (`owner/repo/file.rkllm`), the **filename**
gets stripped off as the "name", only `owner/repo` reaches the server,
and the server returns `Error: Invalid path 'owner/repo'`. **Crucially
the client still prints `Download complete` and exits 0**, so the loop
keeps going and you don't notice. Always verify with
`rkllama_client list` afterwards.

Source: `/opt/rkllama/src/rkllama/client/client.py:309`. Documented in
`docs/how-to/rkllama-models.md` with a warning admonition.

## Removing models — prefer `rm -rf` of the model dir

`rkllama_client rm` wants the original `<file>.rkllm` filename
(awkward — you have to remember the full quantisation suffix).
Direct directory removal is simpler:

```bash
kubectl exec -n rkllama $POD -c rkllama -- rm -rf /opt/rkllama/models/<short-name>
```

**Do not delete `/opt/rkllama/models/cuda/`** — that subdirectory is
the **llamacpp** GGUF models on the same NFS root. Mixing the two
backends in one NFS share is intentional but means rkllama wipes must
exclude `cuda/`.

## Hardware envelope (node04)

- Rockchip RK3588: 6 TOPS NPU (3 × 2 TOPS cores), INT8/INT4 only.
- 32 GB unified RAM (CPU + NPU share). Generic RK1 baseline is 16 GB,
  but node04 is the upgraded module — confirm in `values.yaml`
  comments before assuming.
- Approx W8A8 RAM: 3B ≈ 4 GB, 7B ≈ 9 GB, 8B ≈ 10 GB, 14B ≈ 15 GB
  (tight). Anything larger than ~14 B will not fit a single RK1.

## Recommended quant settings

For a 32 GB node with no other competing workloads:
`w8a8 opt-1 hybrid-ratio-1.0` — plain w8a8 (not group-quantised),
optimisation level 1 (faster), maximum NPU offload. The
`w8a8_g128`/`g256`/`g512` group-quantised variants are slightly better
quality but larger and not always available for all hybrid ratios.

## Finding `.rkllm` conversions on Hugging Face

The active community converters are **`c01zaut`** (broadest catalog,
runtime 1.1.4 builds) and **`ahz-r3v`** (DeepSeek family). Search:

```bash
curl -s "https://huggingface.co/api/models?author=c01zaut&limit=80" \
  | jq -r '.[] | select(.id | test("rk3588"; "i")) | .id'
```

Most useful runtime version is **1.1.4** — older `1.1.0`–`1.1.2`
conversions still work but lack newer model families. **Mistral 7B has
no rkllm conversion** on HF (as of 2026-05); Llama / Qwen / Gemma / Phi
families are all covered.
