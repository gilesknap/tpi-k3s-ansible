# 3. Security Trade-offs in the Unified Auth Framework

Date: 2026-03-01

Status: Accepted

## Context

A security review of the unified auth framework (ADR 0001) raised four
questions about defence-in-depth gaps in individual services. Each finding was
investigated and determined to be acceptable given the layered security model,
but the reasoning should be captured to avoid revisiting the same questions in
future reviews.

The cluster's three-layer auth model is:

1. **Cloudflare Access** — perimeter TFA at the tunnel edge (email challenge).
2. **oauth2-proxy** — ingress-level gateway with GitHub OAuth and an email
   allowlist (``oauth2_emails`` in ``values.yaml``).
3. **Native OIDC / service auth** — per-service SSO and RBAC mapping.

Each layer is independent. A vulnerability at one layer is contained by the
others.

## Decision

Accept the following trade-offs, with documented rationale for each.

### Open WebUI trusts ``X-Auth-Request-Email`` unconditionally

``WEBUI_AUTH_TRUSTED_EMAIL_HEADER`` is set regardless of whether
``enable_oauth2_proxy`` is true or false. If oauth2-proxy were disabled, a
LAN attacker could spoof the header and auto-login as any user.

**Why acceptable:** oauth2-proxy is always enabled in production. When it is
enabled, nginx's ``auth_request_set`` directive overwrites any client-supplied
``X-Auth-Request-Email`` header with the value returned by the auth
sub-request, making external spoofing impossible. The risk only materialises
if an operator explicitly disables oauth2-proxy *and* an attacker has LAN
access — a scenario covered by the operator's own testing responsibility.

**Future hardening:** wrap the ``extraEnvVars`` block in a
``{{- if .Values.enable_oauth2_proxy }}`` conditional so the header trust is
never active without the gateway.

### ArgoCD Dex has no GitHub organisation restriction

The Dex GitHub connector accepts any GitHub account. An authenticated user
with no email match in ``argocd-rbac-cm`` receives ``role:readonly``.

**Why acceptable:** ArgoCD is not exposed to the internet. It was removed from
the Cloudflare tunnel (see ADR 0002) because SSL passthrough is incompatible
with Access header injection. The only access paths are LAN and SSH port
forwarding, both of which require network-level access to the cluster. Even if
an unauthorised GitHub user reached Dex, ``role:readonly`` grants no write
access to applications or cluster resources.

**Future hardening:** add an ``orgs`` restriction to the Dex connector config
so the endpoint is safe if ArgoCD is accidentally re-exposed via tunnel.

### Grafana OAuth allows sign-up from any GitHub user

``allow_sign_up: true`` is set with no ``allowed_organizations`` restriction.
Any GitHub user who completes the OAuth flow gets a Viewer account.

**Why acceptable:** Grafana's OAuth login endpoint is behind both Cloudflare
Access (email TFA) and oauth2-proxy (email allowlist). A GitHub user not on
the allowlist cannot reach the ``/login/generic_oauth`` endpoint. The
``role_attribute_path`` JMESPath expression further restricts the Admin role
to specific emails — everyone else gets Viewer only.

**Future hardening:** add ``allowed_organizations`` to the ``generic_oauth``
config for an additional layer.

### Headlamp ClusterRole grants ``pods/exec`` cluster-wide

The ``headlamp-dashboard`` ClusterRole includes ``pods/exec`` with
``["get", "create"]`` verbs across all namespaces. This is a known privilege
escalation vector in Kubernetes — exec into a pod with mounted secrets grants
access to those secrets.

**Why acceptable:** the previous configuration used ``cluster-admin``, which
granted *all* permissions including secret reads, node access, and RBAC
modification. The new role removes those capabilities and limits write access
to common workload resources. ``pods/exec`` is deliberately retained because
Headlamp's primary value is interactive container debugging (logs, exec,
port-forward). Access is gated by oauth2-proxy (email allowlist) and
Headlamp's native token login — the service account token is not exposed
without authentication.

**Future hardening:** replace the ClusterRoleBinding with namespace-scoped
RoleBindings, excluding sensitive namespaces (``kube-system``, ``argo-cd``,
``cert-manager``, ``sealed-secrets``).

## Consequences

- Future security reviews can reference this ADR instead of re-investigating
  the same trade-offs.
- Each finding has a documented hardening path that can be implemented
  incrementally without blocking the current deployment.
- The layered defence model is the primary security control — individual
  service-level gaps are acceptable only because the outer layers compensate.
  If any outer layer is removed (e.g. Cloudflare Access or oauth2-proxy), the
  service-level gaps become real vulnerabilities and the hardening steps listed
  above should be applied first.
