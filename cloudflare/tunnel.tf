# The tunnel's secret: 32 random bytes, kept only in the local, encrypted
# state. Bump tunnel_secret_rotation to replace it, which rotates the
# tunnel token (see "Rotate the tunnel token" in
# docs/how-to/cloudflare-as-code.md).
resource "random_bytes" "tunnel_secret" {
  length = 32

  keepers = {
    rotation = var.tunnel_secret_rotation
  }
}

# The remotely-managed tunnel. A new secret is an in-place update: the
# tunnel ID, its DNS records and its configuration stay the same, but
# cloudflared needs the new token (output tunnel_token) to reconnect.
resource "cloudflare_zero_trust_tunnel_cloudflared" "cluster" {
  account_id    = var.account_id
  name          = var.tunnel_name
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.tunnel_secret.base64

  lifecycle {
    prevent_destroy = true
  }
}

# The token cloudflared runs with: base64 of the JSON {"a": account ID,
# "s": secret, "t": tunnel ID}, the format cloudflared decodes. It is built
# here rather than read with the cloudflare_zero_trust_tunnel_cloudflared_token
# data source, which needs an edit token (so would break the read-only plan)
# and would be read before an apply rotates the secret. Read it with
# `just cf-seal-tunnel-token`, which seals it without printing it.
output "tunnel_token" {
  description = "The tunnel token for cloudflared (sensitive)."
  sensitive   = true
  value = base64encode(jsonencode({
    a = var.account_id
    s = cloudflare_zero_trust_tunnel_cloudflared.cluster.tunnel_secret
    t = cloudflare_zero_trust_tunnel_cloudflared.cluster.id
  }))
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

# The IDs scripts/cf-tunnel-disconnect needs for the API (not secret).
output "tunnel_ids" {
  description = "The account ID and tunnel ID of the cluster's tunnel."
  value = {
    account_id = var.account_id
    tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.cluster.id
  }
}
