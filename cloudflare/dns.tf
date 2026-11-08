# A proxied CNAME to the tunnel for every tunnel service.
resource "cloudflare_dns_record" "tunnel" {
  for_each = local.tunnel_hostnames

  zone_id = var.zone_id
  name    = each.value
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.cluster.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  settings = {
    flatten_cname = false
  }

  lifecycle {
    # See access_guard.tf.
    precondition {
      condition     = contains(local.access_bypass_hosts, each.value) || local.access_wildcard_covered || contains(local.access_covered, each.value)
      error_message = "${each.value} is routed through the tunnel but no Access app protects it: neither the *.${var.domain} wildcard app nor an app for exactly this hostname has only identity or service-token policies (an app with a path covers only that path). Add or fix the Access app in access.tf, or, if the service is meant to be public, set access_bypass = true on its tunnel_services entry (locals.tf)."
    }
  }
}

# Records that do not go through the tunnel.
resource "cloudflare_dns_record" "dns_only" {
  for_each = var.dns_only_records

  zone_id = var.zone_id
  name    = "${each.key}.${var.domain}"
  type    = each.value.type
  content = each.value.content
  proxied = each.value.proxied
  ttl     = each.value.ttl

  lifecycle {
    # See access_guard.tf. A record that is not proxied never reaches Access.
    precondition {
      condition     = !each.value.proxied || local.access_wildcard_covered || contains(local.access_covered, "${each.key}.${var.domain}")
      error_message = "${each.key}.${var.domain} is proxied but no Access app protects it: neither the *.${var.domain} wildcard app nor an app for exactly this hostname has only identity or service-token policies. Add or fix the Access app in access.tf, or make the record DNS-only (proxied = false)."
    }
  }
}
