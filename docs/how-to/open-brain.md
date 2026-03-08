# Open Brain (AI Memory)

Open Brain is an optional self-hosted [Supabase](https://supabase.com/) stack
that provides persistent AI memory accessible via
[MCP](https://modelcontextprotocol.io/) (Model Context Protocol). It lets
Claude.ai (or any MCP-compatible tool) capture, search, and recall thoughts
across conversations.

:::{note}
This feature requires an **x86/amd64 node** in your cluster. The Supabase
container images do not reliably support ARM64.
:::

## Prerequisites

- An x86 node in your cluster (e.g. `ws03`) with `nvidia_gpu_node` or similar
  entry in `hosts.yml`
- An NFS export for database backups (optional — the database uses Longhorn
  by default)
- [Cloudflare Tunnel](cloudflare-web-tunnel) configured (for external access)
- [OAuth2 proxy](oauth-setup) configured (for Studio dashboard access)

## 1 -- Enable Supabase in values.yaml

Edit **`kubernetes-services/values.yaml`** and add at the end:

```yaml
# Supabase self-hosted stack for Open Brain AI memory.
enable_supabase: true

supabase:
  nfs:
    server: 192.168.1.3      # your NFS server IP
    path: /bigdisk/OpenBrain  # NFS export path (for future use)
```

:::{tip}
The NFS settings are currently used only by the additions chart for potential
future storage needs. The PostgreSQL database uses Longhorn block storage,
which is more reliable for database workloads.
:::

## 2 -- Generate and seal credentials

Generate all the secrets Supabase needs. You will need `openssl`, `python3`
with `PyJWT`, and `kubeseal`.

### Generate raw credentials

```bash
# JWT secret (signs all Supabase tokens)
JWT_SECRET=$(openssl rand -base64 32)

# Postgres password
DB_PASSWORD=$(openssl rand -base64 32)

# Realtime secret key base (Phoenix framework)
REALTIME_SECRET=$(openssl rand -base64 64)

# Meta crypto key (encrypts metadata at rest)
META_CRYPTO_KEY=$(openssl rand -hex 32)

# MCP access key (your x-brain-key for API auth)
MCP_ACCESS_KEY=$(openssl rand -hex 32)

# Dashboard password
DASHBOARD_PASSWORD=$(openssl rand -base64 24)

# Analytics key (required even though analytics is disabled)
ANALYTICS_KEY=$(openssl rand -base64 32)
```

### Generate Supabase JWTs

Install PyJWT if needed (`uv pip install PyJWT`), then generate the anon
and service_role tokens:

```bash
python3 -c "
import jwt, time
secret = '$JWT_SECRET'
print('ANON_KEY=' + jwt.encode(
    {'role': 'anon', 'iss': 'supabase',
     'iat': int(time.time()), 'exp': int(time.time()) + 10*365*24*3600},
    secret, algorithm='HS256'))
print('SERVICE_KEY=' + jwt.encode(
    {'role': 'service_role', 'iss': 'supabase',
     'iat': int(time.time()), 'exp': int(time.time()) + 10*365*24*3600},
    secret, algorithm='HS256'))
"
```

Save the output — you will need the `ANON_KEY`, `SERVICE_KEY`, and especially
the `MCP_ACCESS_KEY` later.

### Create the namespace and seal the secret

```bash
# Create namespace so kubeseal can scope the encryption
kubectl create namespace supabase

# Create and seal all credentials
kubectl create secret generic supabase-credentials \
  --namespace=supabase \
  --from-literal=secret="$JWT_SECRET" \
  --from-literal=anonKey="$ANON_KEY" \
  --from-literal=serviceKey="$SERVICE_KEY" \
  --from-literal=password="$DB_PASSWORD" \
  --from-literal=database=postgres \
  --from-literal=username=admin \
  --from-literal=dashboard-password="$DASHBOARD_PASSWORD" \
  --from-literal=smtp-username=noreply@example.com \
  --from-literal=smtp-password=dummy-not-configured \
  --from-literal=secretKeyBase="$REALTIME_SECRET" \
  --from-literal=cryptoKey="$META_CRYPTO_KEY" \
  --from-literal=mcp-access-key="$MCP_ACCESS_KEY" \
  --from-literal=publicAccessToken="$ANALYTICS_KEY" \
  --from-literal=privateAccessToken="$ANALYTICS_KEY" \
  --from-literal=openAiApiKey=not-configured \
  --dry-run=client -o yaml | \
  kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
  > kubernetes-services/additions/supabase/templates/supabase-secret.yaml
```

:::{important}
Save your `MCP_ACCESS_KEY` somewhere secure — you will need it to configure
the Claude.ai MCP connector. The sealed secret file is safe to commit to Git.
:::

## 3 -- Commit and deploy

```bash
git add kubernetes-services/values.yaml \
        kubernetes-services/additions/supabase/templates/supabase-secret.yaml
git commit -m "Enable Open Brain (Supabase) with sealed credentials"
git push
```

Then deploy via the playbook:

```bash
ansible-playbook pb_all.yml --tags cluster
```

ArgoCD will create the `supabase` Application and deploy all components.
Monitor progress:

```bash
# Watch ArgoCD app status
kubectl get app supabase -n argo-cd -w

# Watch pods come up
kubectl get pods -n supabase -w
```

All 9 pods should reach `Running` status within a few minutes:
db, auth, rest, realtime, storage, functions, studio, kong, meta.

## 4 -- Verify the deployment

### Check the database schema

```bash
# Verify pgvector extension
kubectl exec -n supabase supabase-supabase-db-0 -- \
  psql -U supabase_admin -d postgres \
  -c "SELECT extname FROM pg_extension WHERE extname='vector';"

# Verify thoughts table
kubectl exec -n supabase supabase-supabase-db-0 -- \
  psql -U supabase_admin -d postgres -c "\dt public.*"
```

### Test the PostgREST API

```bash
# Insert a test thought (use your SERVICE_KEY)
curl -s -X POST \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"content":"Test thought","metadata":{"type":"test"}}' \
  http://$(kubectl get svc -n supabase supabase-supabase-kong \
    -o jsonpath='{.spec.clusterIP}'):8000/rest/v1/thoughts

# Retrieve it
curl -s \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  http://$(kubectl get svc -n supabase supabase-supabase-kong \
    -o jsonpath='{.spec.clusterIP}'):8000/rest/v1/thoughts
```

## 5 -- Configure Cloudflare Tunnel

In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/),
add two public hostnames for your tunnel:

| Hostname | Service |
|----------|---------|
| `supabase.<your-domain>` | `http://supabase-supabase-kong.supabase.svc.cluster.local:8000` |
| `supabase-api.<your-domain>` | `http://supabase-supabase-kong.supabase.svc.cluster.local:8000` |

:::{note}
Both hostnames point to Kong. The Studio ingress routes through Kong on
port 8000. The separate hostnames exist so you can apply different
Cloudflare Access policies if desired (e.g. API endpoint open for MCP,
Studio behind browser-based login).
:::

## 6 -- Access Supabase Studio

Supabase Studio is the admin UI for browsing tables, running SQL, and
managing the database schema.

Via ingress (after Cloudflare tunnel setup): **https://supabase.\<your-domain\>**

Via port-forward (works immediately):

```bash
kubectl port-forward svc/supabase-supabase-kong -n supabase 8000:8000
# Open http://localhost:8000 in your browser
```

Login with the dashboard credentials you generated in step 2
(default username: `admin`).

## 7 -- Connect Claude.ai and other clients

Open Brain exposes two interfaces:

- **MCP server** (`brain.<your-domain>/mcp`) — for Claude.ai and other
  MCP-compatible clients. Uses OAuth 2.1 with GitHub identity. See
  {doc}`claude-ai-mcp` for the full setup guide.
- **REST API** (`supabase-api.<your-domain>/functions/v1/open-brain-mcp`) —
  for scripts, CLI tools, and direct API access. Uses `x-brain-key` header
  auth.

See {doc}`claude-ai-mcp` for connecting Claude.ai via the MCP server,
including GitHub OAuth App setup, project instructions, and troubleshooting.

## Disable Open Brain

To remove Supabase from your cluster, set `enable_supabase: false` in
`kubernetes-services/values.yaml`, commit, push, and re-run the playbook.
ArgoCD will prune all Supabase resources. The Longhorn PVC retains your
data until manually deleted.

## Troubleshooting

### Kong OOMKilled

Kong requires at least 2Gi memory limit. If it keeps restarting with
`OOMKilled`, check the resource limits in `templates/supabase.yaml`.

### "No API key found in request"

Supabase Kong uses the `apikey` header (not `Authorization` alone).
Always include both headers:

```bash
-H "apikey: $KEY" -H "Authorization: Bearer $KEY"
```

### Database pod CrashLoopBackOff

If the DB pod fails with `chown: Operation not permitted`, the storage
backend does not support ownership changes. The default configuration uses
Longhorn which handles this correctly. If you switched to NFS, you need
`no_root_squash` on the NFS export.

### ArgoCD "not permitted in project"

The Supabase Helm chart repo must be in the ArgoCD project's `sourceRepos`.
Check `argo-cd/argo-project.yaml` includes:

```yaml
- "https://supabase-community.github.io/supabase-kubernetes"
```
