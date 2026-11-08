# Guard against publishing a hostname without Access in front of it.
#
# The rule: every public proxied hostname (each tunnel_services entry and
# each proxied dns_only_records entry) is behind an Access app that asks
# for an identity or a service token, unless its tunnel_services entry
# says access_bypass = true. Conversely, an Access app that lets anyone in
# may only target hostnames marked that way. Both halves are
# preconditions (on the DNS records in dns.tf and on the Access apps in
# access.tf), so a breach fails `tofu plan` before anything reaches
# Cloudflare.
#
# How Cloudflare picks the app for a request: the most specific
# destination wins, so an exact hostname beats the *.<domain> wildcard,
# and a hostname with a path beats the bare hostname for that path only.
# Hence:
#   - a hostname is covered by the wildcard app, or by an app for exactly
#     that hostname, when that app's policies are all closed;
#   - an app with a path (e.g. scrap's /mcp) covers only that path, so it
#     never covers its hostname on its own;
#   - an app that lets anyone in exposes what it targets, with or without
#     a path, so every hostname it names must be on the allowlist.
#
# A policy lets anyone in if its decision is bypass, or if one of its
# include rules matches anybody: everyone (any email that can sign in), a
# login method on its own (anyone with, say, a GitHub account) or an IP
# range of the whole internet. Within one app Cloudflare evaluates bypass
# policies first, so one such policy opens the whole app. A service-token
# (non_identity) policy is closed: it needs the token. What is not
# detected: rules that are wide by their values, such as a public email
# domain in viewer_email_domains.
#
# The wildcard is trusted only for names one label below the domain
# (a.<domain>, not a.b.<domain>): a deeper name needs its own app.

locals {
  # The allowlist: hostnames whose tunnel_services entry has
  # access_bypass = true.
  access_bypass_hosts = [
    for s in local.tunnel_services : "${s.name}.${var.domain}"
    if lookup(s, "access_bypass", false)
  ]

  access_policy_open = {
    for k, p in local.access_policies : k => (
      p.decision == "bypass" ||
      anytrue([
        for i in coalesce(p.include, []) :
        try(i.everyone != null, false) ||
        try(i.login_method != null, false) ||
        contains(["0.0.0.0/0", "::/0"], try(i.ip.ip, ""))
      ])
    )
  }

  access_app_open = {
    for k, a in local.access_apps : k => anytrue([for p in a.policies : local.access_policy_open[p]])
  }

  # Hostnames each app targets, ignoring any path.
  access_app_hosts = {
    for k, a in local.access_apps : k => distinct([for u in a.uris : split("/", u)[0]])
  }

  # Whole hostnames (no path), including the wildcard, that a closed app
  # covers.
  access_covered = toset(flatten([
    for k, a in local.access_apps : [for u in a.uris : u if !strcontains(u, "/")]
    if !local.access_app_open[k]
  ]))

  access_wildcard_covered = contains(local.access_covered, "*.${var.domain}")
}

# A tunnel_services entry with access_bypass = true but no app that lets
# anyone in: harmless, but the allowlist is wider than it needs to be.
locals {
  access_bypass_unused = sort(setsubtract(local.access_bypass_hosts, flatten([
    for k, hosts in local.access_app_hosts : hosts if local.access_app_open[k]
  ])))
}

check "access_bypass_unused" {
  assert {
    condition     = length(local.access_bypass_unused) == 0
    error_message = "access_bypass = true on ${join(", ", local.access_bypass_unused)}, but no open Access app targets it; drop the flag from its tunnel_services entry (locals.tf)."
  }
}
