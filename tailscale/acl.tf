# The whole tailnet policy file. policy.hujson is a template only for the
# owner's login, so that it stays out of the public repo; the rest is the
# policy as it is sent to Tailscale, comments included.
#
# Tailscale runs the policy's "tests" when the provider validates it at
# plan time and again on apply, and refuses a policy that fails them.
resource "tailscale_acl" "policy" {
  acl = templatefile("${path.module}/policy.hujson", {
    owner_login = var.owner_login
  })
}

# Adopt the live policy instead of overwriting it: without this the first
# apply fails (the provider refuses to replace a non-default policy it has
# not imported). The provider ignores the ID. Once in state this is a no-op.
import {
  to = tailscale_acl.policy
  id = "acl"
}
