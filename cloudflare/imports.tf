# Adopt existing Cloudflare objects listed in var.import_ids (the IDs live
# in the gitignored live.auto.tfvars, so this file stays account-neutral).
# An object missing from var.import_ids is not imported: the plan creates
# it instead, which is what a fresh account wants. Once an object is in
# state its import block is a no-op.
#
# Import ID formats are those of the provider's docs for each resource.

import {
  for_each = var.import_ids.tunnel == null ? toset([]) : toset([var.import_ids.tunnel])
  to       = cloudflare_zero_trust_tunnel_cloudflared.cluster
  id       = "${var.account_id}/${each.value}"
}

import {
  for_each = var.import_ids.tunnel == null ? toset([]) : toset([var.import_ids.tunnel])
  to       = cloudflare_zero_trust_tunnel_cloudflared_config.cluster
  id       = "${var.account_id}/${each.value}"
}

import {
  for_each = var.import_ids.cache_ruleset == null ? toset([]) : toset([var.import_ids.cache_ruleset])
  to       = cloudflare_ruleset.cache
  id       = "zones/${var.zone_id}/${each.value}"
}

import {
  for_each = { for k, v in var.import_ids.idps : k => v if k == "otp" }
  to       = cloudflare_zero_trust_access_identity_provider.otp
  id       = "accounts/${var.account_id}/${each.value}"
}

import {
  for_each = { for k, v in var.import_ids.idps : k => v if k == "github" }
  to       = cloudflare_zero_trust_access_identity_provider.github
  id       = "accounts/${var.account_id}/${each.value}"
}

import {
  for_each = { for k, v in var.import_ids.access_policies : k => v if k == "owner" }
  to       = cloudflare_zero_trust_access_policy.owner
  id       = "${var.account_id}/${each.value}"
}

import {
  for_each = { for k, v in var.import_ids.access_policies : k => v if k == "viewers" }
  to       = cloudflare_zero_trust_access_policy.viewers
  id       = "${var.account_id}/${each.value}"
}

import {
  for_each = { for k, v in var.import_ids.access_policies : k => v if k == "bypass" }
  to       = cloudflare_zero_trust_access_policy.bypass
  id       = "${var.account_id}/${each.value}"
}

import {
  for_each = { for k, v in var.import_ids.access_policies : k => v if k == "scrap_mcp" }
  to       = cloudflare_zero_trust_access_policy.scrap_mcp
  id       = "${var.account_id}/${each.value}"
}

import {
  for_each = { for k, v in var.import_ids.dns_records : k => v if contains(keys(local.tunnel_hostnames), k) }
  to       = cloudflare_dns_record.tunnel[each.key]
  id       = "${var.zone_id}/${each.value}"
}

import {
  for_each = { for k, v in var.import_ids.dns_records : k => v if contains(keys(var.dns_only_records), k) }
  to       = cloudflare_dns_record.dns_only[each.key]
  id       = "${var.zone_id}/${each.value}"
}

import {
  for_each = var.import_ids.access_apps
  to       = cloudflare_zero_trust_access_application.app[each.key]
  id       = "accounts/${var.account_id}/${each.value}"
}

# Every zone has every setting, so these are always imported.
import {
  for_each = local.zone_settings
  to       = cloudflare_zone_setting.this[each.key]
  id       = "${var.zone_id}/${each.key}"
}

# An import_ids.dns_records key that names no record in the config would
# otherwise be skipped silently, and the plan would create a duplicate.
check "dns_import_keys" {
  assert {
    condition = alltrue([
      for k in keys(var.import_ids.dns_records) :
      contains(concat(keys(local.tunnel_hostnames), keys(var.dns_only_records)), k)
    ])
    error_message = "import_ids.dns_records has a key that is neither in tunnel_services nor in dns_only_records."
  }
}
