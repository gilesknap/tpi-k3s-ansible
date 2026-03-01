# 1. Unified Authentication and Authorisation Framework

Date: 2026-03-01

Status: Accepted

## Context

The cluster had three independent authentication layers that did not share a
common identity:

1. **Cloudflare Access** — email-based two-factor challenge at the tunnel edge,
   configured in the Zero Trust dashboard.
2. **oauth2-proxy** — GitHub OAuth gateway in front of nginx ingresses, with an
   email allowlist in ``values.yaml``.
3. **Native service logins** — each application (Grafana, ArgoCD, Headlamp,
   Open WebUI) maintained its own username/password or token-based
   authentication with independent user databases.

This meant that a user accessing the cluster remotely had to authenticate up to
three times with different credentials, and there was no way for a service to
know *who* the user was based on their OAuth identity. Authorisation (what a
user is allowed to do) was configured separately in each service with no
central policy.

Additionally, ArgoCD used TLS passthrough at the ingress, which was
incompatible with both oauth2-proxy's nginx auth sub-request mechanism and
Cloudflare Access header injection. This forced ArgoCD to be LAN-only or
accessed via SSH tunnel.

## Decision

Adopt GitHub OAuth as the single identity provider across all layers, with
email-based role mapping configured centrally in ``values.yaml``.

Specifically:

- **Cloudflare Access** remains as the perimeter defence (no change).
- **oauth2-proxy** remains as the ingress-level gateway for services that lack
  native OIDC support (Longhorn, Headlamp). It also provides defence-in-depth
  for services that *do* have native OIDC.
- **Services with native OIDC support** (Grafana, ArgoCD, Open WebUI) are
  configured to authenticate directly with GitHub, so the user's identity flows
  into the application's RBAC system.
- **Per-service authorisation** is mapped from email addresses. Admin email
  lists in ``values.yaml`` (e.g. ``argocd_admin_emails``,
  ``grafana_admin_emails``) determine who gets elevated roles. Everyone else on
  the ``oauth2_emails`` allowlist gets read-only or default access.
- **ArgoCD** is switched from TLS passthrough to ``server.insecure`` mode
  (see ADR 0002), enabling it to join the tunnel and OAuth framework.

Alternatives considered:

- **Keycloak / Authentik** — full-featured identity providers with fine-grained
  RBAC, but require 1–2 GB of memory and significant operational overhead.
  Overkill for a homelab with a handful of users.
- **Cloudflare as OAuth provider** — possible via Access service tokens, but
  ties identity management entirely to a third-party dashboard with no
  in-repo configuration.
- **Google OAuth** — viable but most expected users are GitHub users, and
  GitHub OAuth was already configured and working.

## Consequences

- Users authenticate once via GitHub and their identity (email) propagates to
  all services that support OIDC.
- Sysadmins configure user access by editing email lists in ``values.yaml``
  and pushing to git — no dashboard clicks required.
- Services without OIDC support (Longhorn, Headlamp) still rely on
  oauth2-proxy as the sole identity gate.
- Each service that gains native OIDC needs a GitHub OAuth App (or shared app
  with multiple callback URLs). Credentials are stored as SealedSecrets.
- The feature can be toggled off by setting ``enable_oauth2_proxy: false``
  and removing the OIDC configuration blocks from the service templates —
  services fall back to their native login pages.
