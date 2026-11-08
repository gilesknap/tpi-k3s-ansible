# Zero Trust Access: reusable policies and applications.

# Login methods (identity providers: one-time PIN and GitHub) are set up
# once in the dashboard and not managed here: Cloudflare never returns an
# OAuth client secret, so code could not keep it in step. The Owner
# policy finds the GitHub login method by name.
data "cloudflare_zero_trust_access_identity_providers" "all" {
  account_id = var.account_id

  lifecycle {
    postcondition {
      condition     = length([for p in self.result : p if p.name == var.owner_login_method]) == 1
      error_message = "Expected exactly one Access login method named \"${var.owner_login_method}\" (set var.owner_login_method; add it in Zero Trust > Settings > Authentication)."
    }
  }
}

locals {
  owner_login_method_id = one([
    for p in data.cloudflare_zero_trust_access_identity_providers.all.result :
    p.id if p.name == var.owner_login_method
  ])
}

# Service token for non-browser clients (scrap's MCP endpoint), looked up
# by name rather than managed: its client secret is shown only once, at
# creation, and has to go to the client anyway, so create or rotate it in
# the dashboard (Zero Trust > Access > Service auth) and keep the secret
# with the client. Managing it here would also put the secret in state.
data "cloudflare_zero_trust_access_service_token" "mcp" {
  account_id = var.account_id
  filter = {
    name = "mcp-access"
  }
}

# --- Reusable policies -------------------------------------------------------

resource "cloudflare_zero_trust_access_policy" "owner" {
  account_id       = var.account_id
  name             = "Owner"
  decision         = "allow"
  session_duration = "24h"
  include          = [for e in var.owner_emails : { email = { email = e } }]
  require = [{
    login_method = { id = local.owner_login_method_id }
  }]
  connection_rules = {
    rdp = {}
  }
}

resource "cloudflare_zero_trust_access_policy" "viewers" {
  account_id       = var.account_id
  name             = "Viewers"
  decision         = "allow"
  session_duration = "6h"
  include = concat(
    [for e in var.viewer_emails : { email = { email = e } }],
    [for d in var.viewer_email_domains : { email_domain = { domain = d } }],
  )
}

resource "cloudflare_zero_trust_access_policy" "bypass" {
  account_id       = var.account_id
  name             = "bypass"
  decision         = "bypass"
  session_duration = "24h"
  include          = [{ everyone = {} }]
  connection_rules = {
    rdp = {}
  }
}

resource "cloudflare_zero_trust_access_policy" "scrap_mcp" {
  account_id = var.account_id
  name       = "scrap-mcp-policy"
  decision   = "non_identity"
  include = [{
    service_token = { token_id = data.cloudflare_zero_trust_access_service_token.mcp.id }
  }]
  connection_rules = {
    rdp = {}
  }
}

# --- Applications ------------------------------------------------------------

locals {
  # The reusable policies above, by the keys that access_apps uses.
  access_policies = {
    owner     = cloudflare_zero_trust_access_policy.owner
    viewers   = cloudflare_zero_trust_access_policy.viewers
    bypass    = cloudflare_zero_trust_access_policy.bypass
    scrap_mcp = cloudflare_zero_trust_access_policy.scrap_mcp
  }

  # Settings common to every self-hosted app, spelled out so the plan
  # compares them with the live values rather than provider defaults.
  access_app_defaults = {
    type                       = "self_hosted"
    session_duration           = "24h"
    app_launcher_visible       = true
    auto_redirect_to_identity  = false
    enable_binding_cookie      = false
    http_only_cookie_attribute = false
    options_preflight_bypass   = false
  }

  access_apps = {
    # Everything under the domain: owner only.
    clusterapps = {
      name     = "clusterapps"
      uris     = ["*.${var.domain}"]
      policies = ["owner"]
    }
    # Read-only dashboards that viewers may see.
    demo = {
      name = "Demo"
      uris = [
        local.tunnel_hostnames["argocd"],
        local.tunnel_hostnames["grafana"],
        local.tunnel_hostnames["argocd-monitor"],
      ]
      policies = ["viewers", "owner"]
    }
    # Public static pages.
    pages = {
      name     = "pages"
      uris     = [local.tunnel_hostnames["pages"]]
      policies = ["bypass"]
    }
    # scrap's MCP endpoint: service token only.
    scrap = {
      name     = "scrap"
      uris     = ["${local.tunnel_hostnames["scrap"]}/mcp"]
      policies = ["scrap_mcp"]
    }
    # ntfy: the phone app cannot do an Access login, so bypass Access;
    # ntfy's token auth is the gate. This app is more specific than
    # clusterapps' wildcard, so it takes precedence for ntfy's hostname.
    ntfy = {
      name     = "ntfy"
      uris     = [local.tunnel_hostnames["ntfy"]]
      policies = ["bypass"]
    }
  }
}

# Not in the provider's schema, so not managed: the imported apps other
# than clusterapps have eager_redirect_cookie_setting = true. An update to one
# of those apps from here may reset it; check it in the dashboard after.
resource "cloudflare_zero_trust_access_application" "app" {
  for_each = local.access_apps

  account_id                 = var.account_id
  name                       = each.value.name
  type                       = local.access_app_defaults.type
  session_duration           = local.access_app_defaults.session_duration
  app_launcher_visible       = local.access_app_defaults.app_launcher_visible
  auto_redirect_to_identity  = local.access_app_defaults.auto_redirect_to_identity
  enable_binding_cookie      = local.access_app_defaults.enable_binding_cookie
  http_only_cookie_attribute = local.access_app_defaults.http_only_cookie_attribute
  options_preflight_bypass   = local.access_app_defaults.options_preflight_bypass

  domain       = each.value.uris[0]
  destinations = [for u in each.value.uris : { type = "public", uri = u }]
  # Reusable policies, in precedence order.
  policies = [
    for i, k in each.value.policies :
    { id = local.access_policies[k].id, precedence = i + 1 }
  ]

  lifecycle {
    # See access_guard.tf.
    precondition {
      condition     = !local.access_app_open[each.key] || length(setsubtract(local.access_app_hosts[each.key], local.access_bypass_hosts)) == 0
      error_message = "Access app \"${each.value.name}\" lets anyone in (a bypass policy, or one that includes everyone) for ${join(", ", sort(setsubtract(local.access_app_hosts[each.key], local.access_bypass_hosts)))}, which is not on the bypass allowlist. Give the app an identity or service-token policy, or, if the service is meant to be public, set access_bypass = true on its tunnel_services entry (locals.tf)."
    }
  }
}
