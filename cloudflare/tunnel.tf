# The remotely-managed tunnel. Its secret is not managed here: cloudflared
# in the cluster runs with the tunnel token from a SealedSecret, and an
# imported tunnel has no secret in state.
resource "cloudflare_zero_trust_tunnel_cloudflared" "cluster" {
  account_id = var.account_id
  name       = var.tunnel_name
  config_src = "cloudflare"

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tunnel_secret]
  }
}

# Public hostnames: one ingress rule per entry in local.tunnel_services,
# then the 404 catch-all.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "cluster" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.cluster.id

  config = {
    ingress = local.tunnel_ingress
  }
}
