# Download RKLLama Models

[RKLLama](https://github.com/NotPunchnox/rkllama) runs LLMs on the RK1's NPU using
Rockchip's proprietary RKLLM runtime. Models must be pre-converted to `.rkllm` format
for the RK3588 chip — standard GGUF/Safetensors files will not work.

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

## Pull a model via Open WebUI

Open WebUI's **Manage Models → Pull a model from Ollama.com** field accepts the
rkllama pull format:

```
owner/repo/filename.rkllm
```

Optionally append a custom short name after a fourth `/`:

```
owner/repo/filename.rkllm/shortname:tag
```

### Example models

**DeepSeek-R1 7B** (reasoning model, ~8 GB, W8A8 optimised):
```
ahz-r3v/DeepSeek-R1-Distill-Qwen-7B-rk3588-rkllm-1.1.4/DeepSeek-R1-Distill-Qwen-7B_W8A8_RK3588_o1.rkllm
```

**Qwen 2.5 3B** (fast, everyday chat, ~3 GB):
```
c01zaut/Qwen2.5-3B-Instruct-RK3588-1.1.4/Qwen2.5-3B-Instruct-rk3588-w8a8-opt-0-hybrid-ratio-0.5.rkllm
```

### Steps

1. Open Open WebUI and go to **Settings → Admin → Models**.
2. In the **Ollama** section, confirm the URL shows `http://rkllama.rkllama.svc.cluster.local:8080`.
3. Paste the model string from above into the **Pull a model from Ollama.com** field.
4. Click the download button (↓). A progress bar will appear as the file downloads
   from Hugging Face directly onto the cluster node.

```{note}
The download goes to the `rkllama-models` PVC on the node, so it persists across
pod restarts. Large models (~8 GB) may take several minutes depending on your
internet connection.
```

## Pull a model via kubectl (alternative)

If the Web UI pull is unavailable, use `rkllama pull` directly in the pod:

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
