# 2. Disable ArgoCD SSL Passthrough

Date: 2026-03-01

Status: Accepted

## Context

ArgoCD was deployed with ``nginx.ingress.kubernetes.io/ssl-passthrough: "true"``,
meaning nginx forwarded raw TLS traffic to the ArgoCD server which terminated
TLS itself. This had two consequences:

1. **Incompatible with oauth2-proxy** — nginx's ``auth-url`` sub-request
   mechanism requires nginx to inspect HTTP headers, which is impossible when
   traffic is passed through as an opaque TLS stream.
2. **Incompatible with Cloudflare tunnel** — Cloudflare Access injects
   identity headers (``Cf-Access-Jwt-Assertion``) into the request, but these
   cannot be injected into a passthrough connection. ArgoCD was therefore
   excluded from the tunnel and accessible only via LAN or SSH tunnel.

The ArgoCD documentation describes two ingress options:

- **Option 1:** SSL passthrough — ArgoCD manages its own TLS certificate.
- **Option 2:** Terminate TLS at the ingress — set
  ``configs.params.server.insecure: true`` and let nginx (with cert-manager)
  handle TLS.

## Decision

Switch to Option 2: set ``server.insecure: true`` in the ArgoCD Helm values
so that nginx terminates TLS. ArgoCD serves plain HTTP internally.

Additionally, move ArgoCD's ingress and ConfigMap management from Ansible
templates to an ArgoCD Application (``kubernetes-services/templates/argocd-config.yaml``),
bringing it in line with all other services. The reusable ingress sub-chart
(``additions/ingress/``) is used, giving ArgoCD the same ``oauth2_proxy`` and
``ssl_redirect`` toggles as every other service.

The Ansible ``cluster`` role retains responsibility for:

- Installing the ArgoCD Helm chart (with ``server.insecure: true``)
- Creating the ArgoCD Project, Git Repository, and root Application

Post-bootstrap configuration (ingress, ConfigMap, RBAC ConfigMap) is managed
by ArgoCD itself.

## Consequences

- ArgoCD can now sit behind oauth2-proxy and the Cloudflare tunnel, matching
  the auth flow of all other services.
- ArgoCD no longer manages its own TLS certificate — cert-manager issues it
  via the ingress, as with every other service.
- ArgoCD's native OIDC (via Dex) continues to work identically — it is
  independent of the TLS termination point.
- **Risk:** A bad ingress change could lock out the ArgoCD UI. Mitigation:
  ``kubectl port-forward svc/argocd-server -n argo-cd 8080:80`` always works
  as a fallback, and the ``argocd`` CLI with ``--core`` mode bypasses the
  ingress entirely.
