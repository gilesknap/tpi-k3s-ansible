# Authentication Architecture

This page explains how authentication works across all cluster services —
from the outer Cloudflare layer through to per-service role assignment.

## Three-layer auth model

Every request to a cluster service passes through up to three authentication
layers. Not all services use all three layers.

```{mermaid}
flowchart TB
    subgraph L1["Layer 1 — Cloudflare Access"]
        CF[Cloudflare Access<br/>email allowlist]
    end

    subgraph L2["Layer 2 — Ingress auth"]
        DEX[Dex OIDC<br/>native provider]
        OAP[oauth2-proxy<br/>GitHub gateway]
    end

    subgraph L3["Layer 3 — App RBAC"]
        RBAC[Per-service roles<br/>admin / viewer / user]
    end

    CF --> DEX
    CF --> OAP
    DEX --> RBAC
    OAP --> RBAC
```

**Layer 1 — Cloudflare Access** gates tunnel-exposed services at the edge.
Users must authenticate with an email on the allowlist before traffic
reaches the cluster. LAN-only services skip this layer entirely.

**Layer 2 — Ingress auth** verifies identity at the cluster boundary.
Services either use Dex (ArgoCD's built-in OIDC provider with a GitHub
connector) or oauth2-proxy (a lightweight reverse-proxy that redirects to
GitHub directly).

**Layer 3 — App RBAC** maps the authenticated identity to a role inside
the application. Emails in the `admin_emails` list in `values.yaml`
receive admin privileges; everyone else gets a read-only or viewer role.
A separate `viewer_emails` list identifies users who can authenticate via
Dex OIDC but receive only read-only access.

## Ingress architecture

Layer 2 authentication is enforced at **ingress-nginx**, the single
entry point for every request that reaches the cluster. Understanding
where ingress-nginx sits clarifies *where* Dex and oauth2-proxy plug in
and *why* the auth-url subrequest pattern works.

```{mermaid}
flowchart TB
    subgraph Internet
        CF[Cloudflare Edge]
    end

    subgraph LAN["Local Network"]
        CLIENT[LAN Client]
    end

    subgraph Cluster["K3s Cluster"]
        ING[ingress-nginx<br/>LoadBalancer on workers]
        SVC1[echo service]
        SVC2[grafana service]
        SVC3[argocd service]
        CFPOD[cloudflared pod]
    end

    CF -->|"tunnel"| CFPOD
    CFPOD -->|"HTTP"| ING
    CLIENT -->|"DNS → worker IP"| ING
    ING --> SVC1 & SVC2 & SVC3
```

Tunnel-routed requests arrive at the `cloudflared` pod via an outbound
tunnel and are forwarded over plain HTTP to ingress-nginx. LAN clients
hit ingress-nginx directly over the worker node IPs. In both cases
ingress-nginx is where OAuth subrequests are issued — either to the
cluster-wide oauth2-proxy or, indirectly, to a service that authenticates
itself against Dex.

### NGINX Ingress (not Traefik)

K3s ships Traefik as its default ingress controller, but this project
disables it (`--disable=traefik`) and deploys **ingress-nginx** instead.
Reasons:

- More widely documented in the Kubernetes ecosystem
- Better support for TLS passthrough (needed for ArgoCD)
- More straightforward configuration model
- Mature `auth-url` / `auth-signin` annotation support, which is what
  oauth2-proxy relies on for the subrequest flow described later in this
  page

### LoadBalancer on workers

The ingress-nginx controller runs on **worker nodes** — in multi-node
clusters the control plane carries a `NoSchedule` taint. DNS entries for
all services must therefore point to worker node IPs, not the control
plane. For single-node clusters, DNS points to that single node.

For round-robin across workers:

```
*.example.com  A  192.168.1.82
*.example.com  A  192.168.1.83
*.example.com  A  192.168.1.84
```

A single worker IP also works — kube-proxy routes traffic to the ingress
pod regardless of which worker receives the connection.

See {doc}`networking` for TLS certificate issuance, Cloudflare tunnel
details, and ArgoCD's TLS termination pattern.

## Auth method summary

| Service | Layer 1 (Cloudflare) | Layer 2 (Ingress) | Layer 3 (App RBAC) |
|---------|---------------------|-------------------|-------------------|
| ArgoCD | Cloudflare Access | Dex (native) | email → `role:admin` / `role:readonly` |
| argocd-monitor | Cloudflare Access | Dex (oauth2-proxy sidecar) | Inherits ArgoCD RBAC |
| Grafana | Cloudflare Access | Dex (`generic_oauth`) | email → `Admin` / `Viewer` |
| Open WebUI | Cloudflare Access | Dex (native OIDC) | email → admin / user |
| Headlamp | Cloudflare Access | oauth2-proxy + ServiceAccount token | — |
| Supabase Studio | Cloudflare Access | oauth2-proxy | Dashboard password |
| Echo | Cloudflare Access | None | None (public test service) |
| Open Brain MCP | Cloudflare Access | OAuth 2.1 (GitHub) | x-brain-key |
| Supabase API | Bypass (no Access) | x-brain-key | — |

## Dex as shared OIDC provider

ArgoCD ships with [Dex](https://dexidp.io/), a federated OIDC provider.
Rather than deploying a separate identity provider, all OIDC-capable
services share ArgoCD's Dex instance. Dex connects to GitHub as its
upstream identity source and issues tokens to four registered static
clients.

```{mermaid}
flowchart LR
    GH[GitHub OAuth App]

    subgraph Dex["ArgoCD Dex Server"]
        CON[GitHub connector]
        CON --> C1[argo-cd]
        CON --> C2[argocd-monitor]
        CON --> C3[grafana]
        CON --> C4[open-webui]
    end

    GH --> CON

    C1 --> ArgoCD
    C2 --> argocd-monitor
    C3 --> Grafana
    C4 --> Open-WebUI
```

All four clients authenticate through a single GitHub OAuth App whose
callback URL points to `https://argocd.<your-domain>/api/dex/callback`.
Each client has its own `client_secret` stored in the `argocd-dex-secret`
SealedSecret.

### Why Dex?

Full-featured identity providers like Authentik or Keycloak need ~2 GB of
RAM — too heavy for a small ARM cluster. Dex is a lightweight OIDC
federation layer that adds negligible overhead because it runs inside the
existing ArgoCD server pod.

## Per-service auth flows

### ArgoCD — native Dex login

ArgoCD has first-class Dex integration. The built-in admin account is
disabled; all users log in via GitHub through Dex.

:::{note}
ArgoCD runs with `server.insecure: true` so that TLS is terminated at
nginx rather than inside the pod. This allows it to be routed through the
Cloudflare tunnel and protected by Cloudflare Access like every other
service.
:::

```{mermaid}
sequenceDiagram
    actor User
    participant ArgoCD
    participant Dex
    participant GitHub

    User->>ArgoCD: Visit argocd.<domain>
    ArgoCD->>Dex: Redirect to /api/dex/auth
    Dex->>GitHub: Redirect to GitHub OAuth
    GitHub->>Dex: Auth code + user info
    Dex->>ArgoCD: ID token (email scope)
    ArgoCD->>ArgoCD: Map email → role:admin or role:readonly
    ArgoCD->>User: Logged in
```

RBAC is configured in `argocd-rbac-cm.yml`. The `scopes` field is set to
`[email]`, and policy rules map specific emails to `role:admin`. Everyone
else gets `role:readonly` (can view applications and logs but not modify).

### argocd-monitor — Dex cross-client auth

argocd-monitor is a dashboard that queries the ArgoCD API. It runs its own
oauth2-proxy **sidecar** (separate from the cluster-wide oauth2-proxy) that
authenticates against Dex.

```{mermaid}
sequenceDiagram
    actor User
    participant Sidecar as oauth2-proxy sidecar
    participant Dex
    participant GitHub
    participant API as ArgoCD API

    User->>Sidecar: Visit argocd-monitor.<domain>
    Sidecar->>Dex: Auth request (scope: audience:server:client_id:argo-cd)
    Dex->>GitHub: Redirect to GitHub OAuth
    GitHub->>Dex: Auth code + user info
    Dex->>Sidecar: ID token with argo-cd audience
    Sidecar->>API: Forward request with token
    API->>API: Validate token (argo-cd audience accepted)
    API->>User: Dashboard data
```

The cross-client flow works because the `argo-cd` static client lists
`argocd-monitor` in its `trustedPeers`. This lets Dex issue tokens with
the `argo-cd` audience to the `argocd-monitor` client, so the ArgoCD API
accepts them.

### Grafana — generic OAuth via Dex

Grafana uses its built-in `auth.generic_oauth` provider pointed at the Dex
endpoints. Password login is disabled — the login page shows only a
"Sign in with GitHub (via Dex)" button.

The `role_attribute_path` JMESPath expression grants `Admin` to emails in
the `admin_emails` list and `Viewer` to everyone else. The client secret
is injected from the `grafana-oauth-secret` SealedSecret.

### Open WebUI — native OIDC via Dex

Open WebUI uses its built-in OIDC support via environment variables. The
`OPENID_PROVIDER_URL` points to the Dex discovery endpoint. Password login
is disabled — the login page shows only an OAuth button.

The `OAUTH_ADMIN_EMAIL` variable (populated from `admin_emails`) controls
who gets the admin role. Everyone else gets the `user` role. The client
secret comes from the `open-webui-oauth-secret` SealedSecret.

:::{important}
The discovery URL must be the full path including
`.well-known/openid-configuration` — Open WebUI's OIDC library does not
follow the 301 redirect from `/api/dex` to `/api/dex/`.
:::

### Headlamp — oauth2-proxy + ServiceAccount token

Headlamp is protected by the cluster-wide oauth2-proxy (admin-only,
same as Supabase Studio). After authenticating via GitHub,
users paste a Kubernetes ServiceAccount token to access the dashboard.
The token is generated with `kubectl create token headlamp -n headlamp`.

### oauth2-proxy services — Headlamp and Supabase Studio

Services without native OIDC support use the cluster-wide oauth2-proxy.
This is a separate authentication path that goes directly to GitHub (not
through Dex). Only emails in the `admin_emails` list can authenticate —
viewer users cannot access these services.

```{mermaid}
sequenceDiagram
    actor User
    participant NGINX as ingress-nginx
    participant OAP as oauth2-proxy
    participant GitHub
    participant Svc as Backend service

    User->>NGINX: Visit supabase-studio.<domain>
    NGINX->>OAP: Auth subrequest
    OAP-->>NGINX: 401 (not authenticated)
    NGINX->>User: Redirect to oauth2.<domain>
    User->>OAP: /oauth2/start
    OAP->>GitHub: Redirect to GitHub OAuth
    GitHub->>OAP: Auth code + user info
    OAP->>OAP: Check email against admin_emails
    OAP->>User: Set session cookie
    User->>NGINX: Retry original request (with cookie)
    NGINX->>OAP: Auth subrequest
    OAP-->>NGINX: 202 + X-Auth-Request-Email header
    NGINX->>Svc: Forward request
    Svc->>User: Response
```

The nginx ingress uses `auth-url` and `auth-signin` annotations to
delegate authentication to oauth2-proxy. Only emails in the
`admin_emails` list are permitted — viewer users and unauthenticated
visitors get a 403 after GitHub login.

:::{important}
The `auth-url` must use the cluster-internal service address
(`oauth2-proxy.oauth2-proxy.svc.cluster.local`), not the external domain.
The external domain resolves via Cloudflare to an IPv6 address that is
unreachable from inside the cluster, causing intermittent 500 errors.
:::

## Full cluster auth map

```{mermaid}
flowchart TB
    Internet((Internet))
    LAN((LAN))

    subgraph Cloudflare["Cloudflare Edge"]
        CFA[Cloudflare Access<br/>email allowlist]
        CFT[Cloudflare Tunnel]
    end

    subgraph Cluster["K3s Cluster"]
        NGINX[ingress-nginx]

        subgraph DexAuth["Dex OIDC (native)"]
            ArgoCD
            Monitor[argocd-monitor]
            Grafana
            OpenWebUI[Open WebUI]
        end

        Headlamp

        subgraph ProxyAuth["oauth2-proxy (admin only)"]
            Headlamp
            Supabase[Supabase Studio]
        end

        Echo

        OAP[oauth2-proxy pod]
        DexPod[Dex<br/>inside ArgoCD]
    end

    GH[GitHub OAuth]

    Internet --> CFA --> CFT --> NGINX
    LAN --> NGINX

    NGINX --> ArgoCD
    NGINX --> Monitor
    NGINX --> Grafana
    NGINX --> OpenWebUI
    NGINX --> Headlamp
    NGINX --> Supabase
    NGINX --> Echo

    ArgoCD <-.-> DexPod
    Monitor <-.-> DexPod
    Grafana <-.-> DexPod
    OpenWebUI <-.-> DexPod
    Headlamp <-.-> OAP
    Supabase <-.-> OAP

    DexPod <-.-> GH
    OAP <-.-> GH
```

Solid lines show request flow; dashed lines show authentication redirects.
All services are exposed via the Cloudflare tunnel and pass through
Cloudflare Access (email allowlist) before reaching the cluster.

## Managing access

Access is controlled by two email lists in `kubernetes-services/values.yaml`:

```yaml
admin_emails:
  - alice@example.com     # full admin access everywhere

viewer_emails:
  - carol@example.com     # read-only access to Dex-authenticated services
```

**Admin emails** are consumed in six places:

| Template / Config | Effect |
|-------------------|--------|
| `oauth2-proxy.yaml` | Email allowlist — only admins can access Supabase Studio and Headlamp |
| `grafana.yaml` | `role_attribute_path` — admin emails get `Admin`, others get `Viewer` |
| `open-webui.yaml` | `OAUTH_ADMIN_EMAIL` — admin emails get admin role |
| `argocd-rbac-cm.yml` | `g, <email>, role:admin` — admin emails get ArgoCD admin |
| Cloudflare Access (manual) | Access policy should include both lists |

**Viewer emails** authenticate via Dex OIDC and receive read-only roles:
ArgoCD `role:readonly`, Grafana `Viewer`, Open WebUI `user`. They
cannot access oauth2-proxy-gated services (Headlamp, Supabase Studio).

:::{important}
`admin_emails` must be kept in sync in two places:

- `kubernetes-services/values.yaml` (for Helm-rendered templates)
- `group_vars/all.yml` (for Ansible-rendered ArgoCD RBAC)

After changing `admin_emails` in `group_vars/all.yml`, re-run
`ansible-playbook pb_all.yml --tags cluster` to update ArgoCD RBAC.
:::

## SealedSecrets for authentication

All OAuth client secrets are encrypted as SealedSecrets and committed
to Git:

| SealedSecret | Location | Contents |
|-------------|----------|----------|
| `argocd-dex-secret` | `additions/argocd/` | GitHub connector credentials + all 5 Dex client secrets |
| `grafana-oauth-secret` | `additions/grafana/` | Grafana's Dex client secret |
| `open-webui-oauth-secret` | `additions/open-webui/` | Open WebUI's Dex client secret |
| `argocd-monitor-oauth-secret` | `additions/argocd-monitor/` | argocd-monitor's Dex client secret + cookie secret |
| `oauth2-proxy-credentials` | `additions/oauth2-proxy/` | GitHub OAuth App credentials + cookie secret |

Re-sealing any of these secrets requires restarting the affected pods
(environment variables from `secretKeyRef` are read at startup, not
watched).

## Design rationale

**Why two auth paths (Dex + oauth2-proxy)?** Dex provides proper OIDC
tokens with scopes and claims, enabling fine-grained RBAC (admin vs
viewer). Services with native OIDC support (ArgoCD, Grafana, Open WebUI) use
Dex for authentication, which allows both admin and viewer users to log
in with differentiated roles. Services without native OIDC (Supabase
Studio) use oauth2-proxy as a binary admin-only gate. Headlamp
uses ServiceAccount token auth for simplicity.

**Why is oauth2-proxy admin-only?** oauth2-proxy has no concept of roles —
it either allows or denies an email. Since Supabase Studio has no
app-level RBAC, giving viewer users access would grant them full
admin capabilities. Restricting oauth2-proxy to `admin_emails` ensures
only trusted operators can reach these destructive admin tools.

**Why not a standalone Dex deployment?** Running Dex inside ArgoCD avoids
deploying another pod and reuses ArgoCD's existing GitHub connector
configuration. The trade-off is that Dex configuration lives in ArgoCD's
ConfigMap rather than a standalone Helm chart.
