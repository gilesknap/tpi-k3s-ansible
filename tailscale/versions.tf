terraform {
  required_version = ">= 1.10.0"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.30.0"
    }
  }

  # State stays local (gitignored, see docs/how-to/tailnet-as-code.md) and
  # is encrypted at rest with the same passphrase as cloudflare/'s state.
  # Plan files are encrypted too: both hold the whole policy, with the
  # owner's login.
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method   = method.aes_gcm.main
      enforced = true
    }

    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
}

# The OAuth client comes from TAILSCALE_OAUTH_CLIENT_ID and
# TAILSCALE_OAUTH_CLIENT_SECRET, set by scripts/tailnet-tofu: a read-only
# client (policy_file:read) for plan, a write client (policy_file) for
# apply. With no tailnet set, the provider uses the client's own tailnet.
provider "tailscale" {}
