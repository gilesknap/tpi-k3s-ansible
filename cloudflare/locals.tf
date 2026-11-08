locals {
  # Every tunnel route goes through the cluster's ingress controller, so
  # oauth2-proxy and the ingress rules apply (see the cloudflare skill).
  ingress_nginx = "http://ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local"

  # The one list of public services. Each entry is a tunnel ingress rule
  # (in this order, ahead of the 404 catch-all) and a proxied CNAME to the
  # tunnel. Removing a service here removes its route and its DNS record.
  #
  #   name           - hostname below var.domain
  #   service        - origin URL; defaults to the ingress controller
  #   origin_request - optional per-route cloudflared settings
  #   cache          - true adds a "cache everything" rule for the host
  #   access_bypass  - true allows an Access app that lets anyone in
  #                    (the bypass policy) for this host; without it the
  #                    plan fails on such an app (see access_guard.tf)
  tunnel_services = [
    { name = "echo" },
    { name = "grafana", service = "${local.ingress_nginx}:80" },
    { name = "headlamp" },
    { name = "oauth2" },
    { name = "argocd-monitor" },
    { name = "home" },
    { name = "argocd" },
    { name = "alertmanager" },
    { name = "minecraft" },
    { name = "scrap" },
    { name = "pages", cache = true, access_bypass = true },
    # Open to the internet behind ntfy's own token auth: it has a bypass
    # Access app (access.tf) and a rate-limiting rule (waf.tf).
    { name = "ntfy", access_bypass = true },
  ]

  tunnel_ingress = concat(
    [
      for s in local.tunnel_services : {
        hostname       = "${s.name}.${var.domain}"
        service        = lookup(s, "service", local.ingress_nginx)
        origin_request = lookup(s, "origin_request", null)
      }
    ],
    # Anything else that reaches the tunnel gets a 404.
    [{ hostname = null, service = "http_status:404", origin_request = null }],
  )

  tunnel_hostnames = { for s in local.tunnel_services : s.name => "${s.name}.${var.domain}" }
  cached_services  = [for s in local.tunnel_services : s.name if lookup(s, "cache", false)]
}
