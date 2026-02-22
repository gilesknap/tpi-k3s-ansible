# Download RKLLama Models

[RKLLama](https://github.com/NotPunchnox/rkllama) runs LLMs on the RK1's NPU using
Rockchip's proprietary RKLLM runtime. Models must be pre-converted to `.rkllm` format
for the RK3588 chip — standard GGUF/Safetensors files will not work.

## Prerequisites — configure your NFS share

RKLLama stores models on an NFS PersistentVolume so that all RK1 nodes share the same
model library and models survive pod restarts. Before deploying rkllama you must point
it at your own NFS server.

Edit **`kubernetes-services/values.yaml`** — this is the single place to configure NFS:

```yaml
rkllama:
  nfs:
    server: 192.168.1.3   # ← replace with your NAS / NFS server IP
    path: /bigdisk/LMModels  # ← replace with the exported path
```

ArgoCD injects these values into the rkllama Helm chart at sync time, so the
PersistentVolume is updated automatically. No other file needs changing.

Commit and push the change; ArgoCD will reconcile the PersistentVolume automatically.

## Find a compatible model on Hugging Face

1. Go to <https://huggingface.co/models> and search for `rk3588 rkllm`.
2. Look for repos that contain `.rkllm` files targeting `rk3588` or `rk3588s`.

   Common naming patterns in the filename to look out for:

   | Token | Meaning |
   |---|---|
   | `W8A8` | 8-bit weights, 8-bit activations (recommended) |
   | `W4A16` | 4-bit weights — smaller, slightly lower quality |
   | `G128` | group-size 128 quantisation variant |
   | `o0` / `o1` | optimisation level 0 / 1 — prefer `o1` for speed |
   | `rk3588` | built for RK3588 / RK1 / Orange Pi 5 |

3. On the HuggingFace repo page, click **Files** and note:
   - The **repo owner** (e.g. `ahz-r3v`)
   - The **repo name** (e.g. `DeepSeek-R1-Distill-Qwen-7B-rk3588-rkllm-1.1.4`)
   - The **exact `.rkllm` filename** (e.g. `DeepSeek-R1-Distill-Qwen-7B_W8A8_RK3588_o1.rkllm`)

## Pull a model with `rkllama-pull`

`rkllama-pull` is a CLI tool that searches HuggingFace for compatible RKLLM models,
lets you pick one interactively, and pulls it into the cluster via `kubectl exec`.
It is installed by the `tools` Ansible role into `$BIN_DIR` (default `/root/bin`).

```bash
rkllama-pull [search terms ...]
```

If you omit search terms you will be prompted:

```
$ rkllama-pull deepseek 7b

Searching HuggingFace for: 'deepseek 7b rk3588 rkllm' ...

Found 4 repo(s):

   1.  ahz-r3v/DeepSeek-R1-Distill-Qwen-7B-rk3588-rkllm-1.1.4
   2.  ...

Select repo [1-4]: 1

Fetching file list from ahz-r3v/DeepSeek-R1-Distill-Qwen-7B-rk3588-rkllm-1.1.4 ...

Available .rkllm files:

   1.  DeepSeek-R1-Distill-Qwen-7B_W8A8_RK3588_o1.rkllm
   2.  DeepSeek-R1-Distill-Qwen-7B_W4A16_RK3588_o0.rkllm

Select file [1-2]: 1

Resolving rkllama pod ...
Using: pod/rkllama-xyzab

Pulling: ahz-r3v/DeepSeek-R1-Distill-Qwen-7B-rk3588-rkllm-1.1.4/DeepSeek-R1-Distill-Qwen-7B_W8A8_RK3588_o1.rkllm
(Large models may take several minutes)

50%
100%
...
Done. Open WebUI will pick up the new model within ~30 seconds.
```

```{note}
The download goes to the `rkllama-models` PVC on the node and persists across pod
restarts. Large models (~8 GB) may take several minutes depending on your connection.
```

```{note}
Open WebUI's built-in model pull dialog is **not supported** — rkllama returns
plain-text progress that the WebUI cannot parse. Use `rkllama-pull` instead.
```

## Pull a model directly via kubectl

If you prefer to skip the interactive tool, use `rkllama pull` directly in the pod:

```bash
kubectl exec -n rkllama -it \
  $(kubectl get pod -n rkllama -l app=rkllama -o name | head -1) \
  -c rkllama -- rkllama pull
```

Enter the repo ID and filename when prompted:

```
Repo ID: ahz-r3v/DeepSeek-R1-Distill-Qwen-7B-rk3588-rkllm-1.1.4
File:    DeepSeek-R1-Distill-Qwen-7B_W8A8_RK3588_o1.rkllm
```

Or pass them as a single argument:

```bash
kubectl exec -n rkllama -it \
  $(kubectl get pod -n rkllama -l app=rkllama -o name | head -1) \
  -c rkllama -- rkllama pull \
  ahz-r3v/DeepSeek-R1-Distill-Qwen-7B-rk3588-rkllm-1.1.4/DeepSeek-R1-Distill-Qwen-7B_W8A8_RK3588_o1.rkllm
```

## List and delete models

**List installed models:**

```bash
kubectl exec -n rkllama \
  $(kubectl get pod -n rkllama -l app=rkllama -o name | head -1) \
  -c rkllama -- rkllama list
```

**Delete a model** (use the short name shown by `list`):

```bash
kubectl exec -n rkllama \
  $(kubectl get pod -n rkllama -l app=rkllama -o name | head -1) \
  -c rkllama -- rkllama rm deepseek-r1-distill-qwen-7b
```

## Memory limits

The RK1 has 16 GB shared between CPU and NPU. Approximate model RAM usage:

| Model size | Quantisation | Approx. RAM |
|---|---|---|
| 3B | W8A8 | ~4 GB |
| 7B | W8A8 | ~9 GB |
| 8B | W8A8 | ~10 GB |
| 14B | W8A8 | ~15 GB (tight) |

Models larger than ~14B will not fit on a single RK1 node.
