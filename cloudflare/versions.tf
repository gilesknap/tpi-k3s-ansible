terraform {
  required_version = ">= 1.10.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.28.1"
    }
  }

  # State stays local (gitignored, see docs/how-to/cloudflare-as-code.md)
  # and is encrypted at rest with a passphrase. Plan files are encrypted
  # too: both hold the account's IDs and the owner and viewer emails.
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

# The API token comes from CLOUDFLARE_API_TOKEN, set by scripts/cf-tofu:
# a read-only token for plan, an edit token for apply.
provider "cloudflare" {}
