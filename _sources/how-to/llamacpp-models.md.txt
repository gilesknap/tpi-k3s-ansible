# llama.cpp CUDA Models

[llama.cpp](https://github.com/ggml-org/llama.cpp) is an OpenAI-compatible LLM inference
server with CUDA acceleration for NVIDIA GPUs. It serves GGUF-format models and integrates
with Open WebUI alongside the RKLLama NPU backend.

## Prerequisites

### 1 — Add an NVIDIA GPU node to the inventory

In `hosts.yml`, add your GPU machine to `extra_nodes` with `nvidia_gpu_node: true`:

```yaml
extra_nodes:
  hosts:
    ws03:
      nvidia_gpu_node: true  # installs NVIDIA container toolkit
```

Then run the full provisioning for that node:

```bash
ansible-playbook pb_all.yml --tags servers,k3s --limit ws03
```

This will:

- Install the NVIDIA GPU driver and container toolkit
- Configure k3s's containerd to use the NVIDIA runtime as default
- Label the node `nvidia.com/gpu.present=true` so the device plugin DaemonSet schedules there
- Join the node to the K3s cluster

### 2 — Configure your NFS share

llama.cpp stores models on an NFS PersistentVolume. Keep GGUF models in a **separate
subdirectory** from RKLLama — the two backends use incompatible model formats.

Edit **`kubernetes-services/values.yaml`**:

```yaml
llamacpp:
  nfs:
    server: 192.168.1.3           # ← your NFS server IP
    path: /bigdisk/LMModels/cuda  # ← separate from rkllama's path
  model:
    file: "mistral-7b-instruct-v0.2.Q4_K_M.gguf"  # ← model to load
    gpuLayers: 99      # offload all layers; reduce if VRAM is insufficient
    contextSize: 8192
    parallel: 4
    memoryLimit: "24Gi"
```

:::{warning}
Do not share the NFS path with RKLLama. RKLLama uses `.rkllm` files (Rockchip NPU
format) and llama.cpp uses `.gguf` files (GGUF/GGML format). They cannot use each
other's models.
:::

Commit and push the change; ArgoCD will reconcile the PersistentVolume automatically.

## Find a compatible GGUF model on Hugging Face

llama.cpp loads any GGUF-format model. A good starting point:

1. Go to <https://huggingface.co/models> and search for `GGUF`.
2. Look for quantised variants — Q4_K_M is a good balance of quality and VRAM use:

   | Token | Meaning |
   |---|---|
   | `Q4_K_M` | 4-bit quantisation, medium quality — recommended |
   | `Q5_K_M` | 5-bit — better quality, more VRAM |
   | `Q8_0` | 8-bit — near-lossless, needs ~8GB VRAM for 7B |
   | `F16` | Full float16 — maximum quality, needs most VRAM |

3. Note the **exact filename** you want (e.g.
   `mistral-7b-instruct-v0.2.Q4_K_M.gguf`).

## Download a model

Use the `llamacpp-pull` script (installed by the `tools` role) to search HuggingFace
and download directly to the cluster's NFS share:

```bash
llamacpp-pull mistral 7b
```

The script will:
1. Search HuggingFace for matching GGUF repos
2. Let you pick a repo and a specific `.gguf` file
3. Download it via `kubectl exec` into the llamacpp pod's `/models` volume
4. Offer to activate the model immediately (`--set`)

### Manual download via kubectl exec

If you prefer to download manually, exec into the llamacpp pod directly:

```bash
kubectl get pods -n llamacpp

kubectl exec -n llamacpp <pod-name> -- \
  curl -L -o /models/my-model.Q4_K_M.gguf \
  https://huggingface.co/<owner>/<repo>/resolve/main/<filename>.gguf
```

The download runs inside the pod and writes directly to NFS.

## Update the model filename in values.yaml

After downloading, update `llamacpp.model.file` in `kubernetes-services/values.yaml`
to match the filename you downloaded, then commit and push:

```bash
git add kubernetes-services/values.yaml
git commit -m "Update llamacpp model to <new filename>"
git push
```

ArgoCD will sync the change, the llamacpp pod will restart, and the model will load
automatically. Once running, it appears in Open WebUI's model dropdown under the
OpenAI API section.

## Verify the model is loaded

```bash
# Check pod is running
kubectl get pods -n llamacpp

# Confirm the model is ready
kubectl logs -n llamacpp -l app=llamacpp --tail=5
# Should end with: "main: server is listening on http://0.0.0.0:8080"

# Test the API directly
curl http://llamacpp.<your-domain>/v1/models
```

## Adjust GPU memory usage

If the model fails to load due to insufficient VRAM, reduce `gpuLayers` in
`kubernetes-services/values.yaml`. Each layer offloads roughly equal amounts of VRAM;
setting a lower value causes remaining layers to run on CPU:

```yaml
llamacpp:
  model:
    gpuLayers: 20    # offload 20 layers to GPU, rest on CPU
    memoryLimit: "12Gi"  # reduce memory limit accordingly
```

A 7B Q4_K_M model at full offload (`gpuLayers: 99`) requires approximately 4–5 GB VRAM.
