# Rate limiting (the zone's http_ratelimit entry point ruleset; there is
# one per zone, so every rate-limiting rule goes in this resource).
#
# The values fit Cloudflare's Free plan, which allows one rule, a 10 s
# counting period, a 10 s mitigation timeout, counting per IP (ip.src
# with cf.colo.id) and only the URI path (and Verified Bot) in the
# expression: not the hostname. On Pro or above, match the host instead,
# (http.host eq "ntfy.<domain>"), and lengthen the period and timeout.
locals {
  # ntfy's URL paths: its topics (the topics in `access` in
  # kubernetes-services/additions/ntfy/values.yaml), each with its
  # subscribe endpoints below it (/<topic>/json, /sse, /ws, ...), and its
  # /v1/ API. The rule matches these paths on every host in the zone; no
  # other service uses them.
  ntfy_topics = ["cluster-alerts", "vps-alerts"]
  ntfy_path_patterns = concat(
    flatten([for t in local.ntfy_topics : ["/${t}", "/${t}/*"]]),
    ["/v1/*"],
  )
}

resource "cloudflare_ruleset" "rate_limit" {
  zone_id     = var.zone_id
  kind        = "zone"
  name        = "default"
  phase       = "http_ratelimit"
  description = ""

  rules = [
    {
      # About 100 requests a minute per client (20 in 10 s), then blocked
      # for 10 s. ntfy's own per-visitor limits still apply behind it.
      description = "ntfy"
      enabled     = true
      expression = join(" or ", [
        for p in local.ntfy_path_patterns : "(http.request.uri.path wildcard r\"${p}\")"
      ])
      action = "block"
      ratelimit = {
        characteristics     = ["ip.src", "cf.colo.id"]
        period              = 10
        requests_per_period = 20
        mitigation_timeout  = 10
      }
    }
  ]
}
