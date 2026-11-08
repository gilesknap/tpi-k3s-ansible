# Zone settings that differ from Cloudflare's defaults or that matter for
# security. Other settings are left at their defaults and unmanaged.
locals {
  zone_settings = {
    ssl              = "strict"
    min_tls_version  = "1.2"
    always_use_https = "on"
    security_level   = "medium"
    ipv6             = "on"
    tls_client_auth  = "on"
    security_header = {
      strict_transport_security = {
        enabled            = true
        max_age            = 15552000 # 180 days
        include_subdomains = true
        preload            = false
        nosniff            = true
      }
    }
  }
}

resource "cloudflare_zone_setting" "this" {
  for_each = local.zone_settings

  zone_id    = var.zone_id
  setting_id = each.key
  value      = each.value
}

# The zone's cache rules (the http_request_cache_settings entry point).
resource "cloudflare_ruleset" "cache" {
  zone_id     = var.zone_id
  kind        = "zone"
  name        = "default"
  phase       = "http_request_cache_settings"
  description = ""

  rules = [
    for name in local.cached_services : {
      ref         = lookup(var.cache_rule_refs, name, null)
      description = name
      enabled     = true
      expression  = "(http.host wildcard r\"${local.tunnel_hostnames[name]}\")"
      action      = "set_cache_settings"
      action_parameters = {
        cache = true
        browser_ttl = {
          mode = "respect_origin"
        }
      }
    }
  ]
}
