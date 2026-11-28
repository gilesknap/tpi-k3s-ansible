# The real values go in the gitignored live.auto.tfvars (copy
# live.auto.tfvars.example).

variable "state_passphrase" {
  description = "Passphrase for OpenTofu state and plan encryption (16+ characters). Set by scripts/tailnet-tofu."
  type        = string
  sensitive   = true
}

# Not marked sensitive: that would hide the whole policy in the plan, and
# the plan's diff is how a change is reviewed.
variable "owner_login" {
  description = "The tailnet owner's login (an email), put in place of owner_login in policy.hujson. Kept out of the public repo."
  type        = string
}
