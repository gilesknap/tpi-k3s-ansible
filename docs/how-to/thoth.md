# thoth (Slack PKM + Hindsight)

[thoth](https://github.com/gilesknap/thoth) is an optional Slack capture
daemon plus an HTTP [MCP](https://modelcontextprotocol.io/) server backed by
a networked [Hindsight](https://github.com/vectorize-io/hindsight) semantic
index. The cluster deploys it from the **OCI Helm chart** published by the
thoth repo's CI; this overlay only ships the cluster-specific
{doc}`SealedSecret <manage-sealed-secrets>` and the ArgoCD `Application`.

:::{note}
The chart is amd64-only (defaults to `nodeSelector: kubernetes.io/arch: amd64`)
because the published image is single-arch. The embedded Hindsight Postgres
data lives on a `ReadWriteOnce` `local-path` PVC, so the pod sticks to
whichever amd64 node it first schedules on. Cordon or taint the other amd64
nodes if you want to pin it explicitly.
:::

## Prerequisites

- An x86/amd64 node in your cluster
- A Slack app with bot + app-level (socket-mode) tokens
- An [Anthropic API key](https://console.anthropic.com/) (used by both the
  MCP server and Hindsight for fact extraction)
- A [Firecrawl](https://firecrawl.dev/) API key (URL ingestion)
- A GitHub fine-grained PAT with `contents:write` on your PKM vault repo
- [Cloudflare Tunnel](cloudflare-web-tunnel) (or any way to reach the
  in-cluster ingress) if you want the MCP endpoint from outside

## 1 -- Enable thoth in values.yaml

Edit `kubernetes-services/values.yaml`:

```yaml
enable_thoth: true
thoth:
  chart_version: "0.7.0-beta.2"
  image_tag: "0.7.0-beta.2"
```

Bump both versions in lockstep when a new tag is published to
`oci://ghcr.io/gilesknap/charts/thoth`.

## 2 -- Seal the thoth-env secret

The upstream chart expects a pre-existing Secret named `thoth-env` in the
`thoth` namespace. Build a plaintext Secret manifest and seal it:

```bash
cat > /tmp/thoth-env.secret.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: thoth-env
  namespace: thoth
type: Opaque
stringData:
  ANTHROPIC_API_KEY: "sk-ant-..."
  FIRECRAWL_API_KEY: "fc-..."
  GITHUB_PKM_VAULT_TOKEN: "github_pat_..."
  SLACK_BOT_TOKEN: "xoxb-..."
  SLACK_APP_TOKEN: "xapp-..."
  SLACK_ALLOWED_USERS: "U0123ABC"      # comma-separated Slack user IDs
  SLACK_CAPTURE_CHANNEL: "C0123ABC"    # channel ID, not name
  SLACK_SUMMARY_CHANNEL: "C0123ABC"
  THOTH_MCP_API_KEYS: "$(openssl rand -hex 32)"
EOF
chmod 600 /tmp/thoth-env.secret.yaml

kubeseal --controller-name sealed-secrets \
         --controller-namespace kube-system \
         --format yaml \
  < /tmp/thoth-env.secret.yaml \
  > kubernetes-services/additions/thoth/templates/thoth-secret.yaml

rm /tmp/thoth-env.secret.yaml
```

`SLACK_ALERT_CHANNEL` is optional; thoth falls back to the capture channel
when it is absent. The Hindsight pod reuses `ANTHROPIC_API_KEY` from the
same Secret for its fact-extraction LLM.

## 3 -- Commit and deploy

```bash
git add kubernetes-services/values.yaml \
        kubernetes-services/templates/thoth.yaml \
        kubernetes-services/additions/thoth/
git commit -m "Enable thoth via published OCI Helm chart"
git push
```

Then deploy via the playbook:

```bash
ansible-playbook pb_all.yml --tags cluster
```

ArgoCD creates the `thoth` Application and pulls the chart from
`oci://ghcr.io/gilesknap/charts`. Watch progress:

```bash
kubectl get app thoth -n argo-cd -w
kubectl get pods -n thoth -w
```

All thoth pods (Slack daemon, MCP server, Hindsight) should reach
`Running` on the pinned node within a few minutes.

## 4 -- Smoke test

- Send a message in your `SLACK_CAPTURE_CHANNEL` and confirm thoth files a
  page in the PKM vault repo.
- `curl -H 'Authorization: Bearer <THOTH_MCP_API_KEYS value>' \
     https://thoth.<cluster_domain>/mcp` should respond.
- Trigger the manual reindex:

  ```bash
  kubectl -n thoth create job --from=cronjob/thoth-reindex manual-reindex
  ```

## Disable thoth

Set `enable_thoth: false` in `kubernetes-services/values.yaml`, commit,
push, and re-run the playbook. ArgoCD will prune the Application. The
embedded Hindsight Postgres data lives on a `local-path` PVC that is
**not** preserved across cluster rebuilds — back up the bank first if you
need it.
