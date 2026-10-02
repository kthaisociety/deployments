# One project's Dokploy side: the Dokploy project and its environments, and per environment a provider
# token (minted from OpenBao's dokploy-provider role), a vault provider holding it, and, once
# release.yaml names an image for it, the app itself with its volumes. Env is the plain `env` values
# plus one generated OpenBao reference per secret name, so no secret value is ever in git or state.

terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
    dokploy = {
      source = "vanillauys/dokploy"
    }
  }
}

locals {
  defaults = try(var.config.defaults, {})
  image    = lower(try(var.config.image, "ghcr.io/${var.config.repo}"))

  # Each environment's settings: defaults, then that environment's own values on top.
  environments = {
    for e, c in var.config.environments : e => {
      env     = merge(try(local.defaults.env, {}), try(c.env, {}))
      secrets = distinct(concat(try(local.defaults.secrets, []), try(c.secrets, [])))
      shared  = merge(try(local.defaults.shared, {}), try(c.shared, {}))
      volumes = merge(try(local.defaults.volumes, {}), try(c.volumes, {}))
      image   = try(var.release[e], null)
    }
  }

  # Same names as kthaisociety/infrastructure's modules/project-secrets.
  provider_name = { for e, _ in local.environments : e => "${var.name}-${e}" }
  secret_path   = { for e, _ in local.environments : e => "${var.name}/${e}" }
  policy        = { for e, _ in local.environments : e => "dokploy-project-${var.name}-${e}" }

  deployed = { for e, c in local.environments : e => c if c.image != null }
}

resource "dokploy_project" "this" {
  name        = var.name
  description = "Managed by github.com/kthaisociety/deployments (projects/${var.name})"
}

# Dokploy makes `production` with the project; other environments (staging) are made here.
resource "dokploy_environment" "this" {
  for_each   = { for e, _ in local.environments : e => e if e != "production" }
  project_id = dokploy_project.this.id
  name       = each.key
}

locals {
  environment_ids = {
    for e, _ in local.environments :
    e => e == "production" ? dokploy_project.this.production_environment_id : dokploy_environment.this[e].id
  }
}

# Periodic orphan from dokploy-provider, which only grants the dokploy-project-* policies that
# kthaisociety/infrastructure wrote. Any apply within 14 days of expiry renews it, and the token string
# doesn't change on renewal; the weekly scheduled apply keeps it alive when nothing else changes.
resource "vault_token" "provider" {
  for_each          = local.environments
  role_name         = "dokploy-provider"
  policies          = [local.policy[each.key]]
  no_default_policy = true
  renewable         = true
  renew_min_lease   = 14 * 24 * 3600
  renew_increment   = 768 * 3600
  display_name      = "dokploy-${local.provider_name[each.key]}"
}

# Lets the environment's app resolve ${{vault.<project>-<env>.…}} references with that token.
resource "dokploy_vault_provider" "this" {
  for_each = local.environments
  name     = local.provider_name[each.key]

  hashicorp = {
    url      = "http://openbao:8200"
    mount    = "secret"
    token_wo = vault_token.provider[each.key].client_token
    # A re-minted token reaches Dokploy without anyone bumping a number.
    token_wo_version = parseint(substr(sha256(vault_token.provider[each.key].client_token), 0, 8), 16)
  }
  assignments = [{
    project_id      = dokploy_project.this.id
    environment_ids = [local.environment_ids[each.key]]
  }]
  # Fails the apply if Dokploy's server can't reach OpenBao with the token, or the token is wrong.
  verify_connection = true
}

locals {
  env_lines = {
    for e, c in local.environments : e => join("\n", concat(
      [for k in sort(keys(c.env)) : "${k}=${c.env[k]}"],
      [for k in c.secrets :
      "${k}=$${{vault.${local.provider_name[e]}.${local.secret_path[e]}:${k}}}"],
      flatten([for name, ks in c.shared : [for k in ks :
      "${k}=$${{vault.${local.provider_name[e]}.shared/${name}/${e}:${k}}}"]]),
    ))
  }
}

resource "dokploy_application" "this" {
  for_each        = local.deployed
  name            = var.name
  app_name_prefix = "${var.name}-${each.key}"
  environment_id  = local.environment_ids[each.key]

  # The exact image, tag@digest, from release.yaml. Public on GHCR: no registry credentials.
  docker = {
    image = each.value.image
  }

  env             = local.env_lines[each.key]
  create_env_file = false
  # Deploys happen when release.yaml or the config changes, through this repo, never on their own.
  auto_deploy      = false
  deploy_on_change = true

  depends_on = [dokploy_vault_provider.this]

  lifecycle {
    precondition {
      condition     = startswith(each.value.image, "${local.image}:") && strcontains(each.value.image, "@sha256:")
      error_message = "release.yaml's ${each.key} image must be ${local.image}:<tag>@sha256:<digest>."
    }
  }
}

locals {
  volumes = merge([
    for e, c in local.deployed : {
      for path, name in c.volumes : "${e}:${path}" => {
        env    = e
        path   = path
        volume = "${var.name}-${e}-${name}"
      }
    }
  ]...)
}

resource "dokploy_mount" "volume" {
  for_each     = local.volumes
  service_id   = dokploy_application.this[each.value.env].id
  service_type = "application"
  type         = "volume"
  volume_name  = each.value.volume
  mount_path   = each.value.path
}
