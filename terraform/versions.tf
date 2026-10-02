terraform {
  required_version = ">= 1.11"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    dokploy = {
      source = "vanillauys/dokploy"
      # 1.8 targets Dokploy v0.30.8, the version we run.
      version = "~> 1.8.0"
    }
  }

  # The same bucket and CI credential as kthaisociety/infrastructure, under its own key and its own
  # passphrase: GleSYS credentials cover the whole instance, so the passphrase is what keeps the two
  # states unreadable to each other. The bucket is versioned, so an overwritten state can be restored.
  backend "s3" {
    bucket    = "kthais-tfstate"
    key       = "deployments/terraform.tfstate"
    endpoints = { s3 = "https://objects.dc-sto1.glesys.net" }
    region    = "us-east-1" # placeholder; GleSYS ignores it, but request signing needs one

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true

    # GleSYS ignores conditional writes, so a lockfile wouldn't lock. CI runs one apply at a time.
    use_lockfile = false
  }

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

# Logs in with the job's GitHub OIDC token to the deployments-ci role, which only mints provider tokens
# (kthaisociety/infrastructure: terraform/openbao/deployments.tf). skip_child_token: the minted tokens
# are orphans from the dokploy-provider role, not children of this short login.
provider "vault" {
  address          = "https://bao.kthais.com"
  skip_child_token = true

  auth_login_jwt {
    role = "deployments-ci"
    jwt  = var.openbao_jwt
  }
}

# Reads DOKPLOY_API_KEY: the key of the Dokploy user "Deployments CI" (ops+dokploy-deployments@kthais.com),
# an admin: members can't create or manage vault providers, and custom roles need a paid license.
provider "dokploy" {
  endpoint = "https://synapse.aisociety.se"
}
