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
}
