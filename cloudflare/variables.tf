# Per-account values. The real ones go in the gitignored live.auto.tfvars
# (copy live.auto.tfvars.example); nothing here is specific to one account.

variable "state_passphrase" {
  description = "Passphrase for OpenTofu state and plan encryption (16+ characters). Set by scripts/cf-tofu."
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account ID."
  type        = string
}

variable "zone_id" {
  description = "Zone ID of the cluster's domain."
  type        = string
}

variable "domain" {
  description = "The cluster's public domain (the Cloudflare zone), e.g. example.com."
  type        = string
}

variable "access_team_name" {
  description = "Zero Trust team name (the <team> in <team>.cloudflareaccess.com)."
  type        = string
}

variable "tunnel_name" {
  description = "Name of the remotely-managed cloudflared tunnel."
  type        = string
}

variable "owner_emails" {
  description = "Emails allowed by the Owner policy (full access to every service)."
  type        = list(string)
}

variable "viewer_emails" {
  description = "Emails allowed by the Viewers policy (the Demo app's read-only services)."
  type        = list(string)
  default     = []
}

variable "viewer_email_domains" {
  description = "Email domains allowed by the Viewers policy."
  type        = list(string)
  default     = []
}

variable "github_client_id" {
  description = "Client ID of the GitHub OAuth app behind the GitHub login method."
  type        = string
}

variable "github_client_secret" {
  description = <<-EOT
    Client secret of the GitHub OAuth app. Cloudflare never returns it, so
    leave it null for day-to-day plans; set it (TF_VAR_github_client_secret)
    only to rotate the secret or when changing the GitHub login method.
  EOT
  type        = string
  sensitive   = true
  default     = null
}

variable "dns_only_records" {
  description = <<-EOT
    DNS records that are not tunnel routes (e.g. a LAN-only name or a VPS
    relay's public IP), keyed by the record's name below the domain.
  EOT
  type = map(object({
    type    = string
    content = string
    proxied = optional(bool, false)
    ttl     = optional(number, 1)
  }))
  default = {}
}

variable "import_ids" {
  description = <<-EOT
    IDs of existing Cloudflare objects to adopt into state with import
    blocks (imports.tf). Leave empty for a fresh account: the resources are
    then created instead. Once imported, the entries are harmless no-ops.
  EOT
  type = object({
    tunnel          = optional(string)
    dns_records     = optional(map(string), {})
    access_apps     = optional(map(string), {})
    access_policies = optional(map(string), {})
    idps            = optional(map(string), {})
    cache_ruleset   = optional(string)
  })
  default = {}
}

variable "cache_rule_refs" {
  description = "Existing cache rule refs, keyed by service name, so imported rules keep their IDs."
  type        = map(string)
  default     = {}
}
