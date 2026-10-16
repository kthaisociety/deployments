# One project's Dokploy side: the Dokploy project and its environments, and per environment a provider
# token (minted from OpenBao's dokploy-provider role), a vault provider holding it, the app and its
# volumes. Env is the plain `env` values plus one generated OpenBao reference per secret name, so no app
# secret value is ever in git or state. (The provider tokens themselves are in this repo's state,
# encrypted with its passphrase: whoever can decrypt that state can use them.)
#
# Every environment's app and volumes exist from the start, but an app only deploys once release.yaml
# names its image. So its first deploy already has its volumes (a mount can only be attached to an app
# that exists), and a release.yaml line set back to null never deletes an app.

terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
    dokploy = {
      source  = "vanillauys/dokploy"
      version = "1.8.0"
    }
    random = {
      source = "hashicorp/random"
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
      domains = try(c.domains, {})
      # Absent/null in both: no Redis. Otherwise merge settings, with the environment taking priority.
      redis = (try(local.defaults.redis, null) == null && try(c.redis, null) == null ? null :
      merge(coalesce(try(local.defaults.redis, null), {}), coalesce(try(c.redis, null), {})))
      # Required for every environment (check enforces it too): a missing line must fail, not quietly
      # read as "no image".
      image = var.release[e]
    }
  }

  # Same names as kthaisociety/infrastructure's modules/project-secrets.
  provider_name = { for e, _ in local.environments : e => "${var.name}-${e}" }
  secret_path   = { for e, _ in local.environments : e => "${var.name}/${e}" }
  policy        = { for e, _ in local.environments : e => "dokploy-project-${var.name}-${e}" }

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

# Redis credentials follow the Postgres design in deployments#17. The password only passes through
# ephemeral values and write-only fields. Applications receive OpenBao references, never the values.
#
# Write the password once, then read it back before creating Redis. If an apply fails after the write,
# a retry must use the stored password, not the new value from the ephemeral generator.
# The app-facing secret follows Redis because its internal host name is assigned at creation.
# Removing Redis or either secret requires a deliberate removed block, not a project.yaml edit alone.
locals {
  redis = {
    for e, c in local.environments : e => c.redis
    if c.redis == null ? false : try(c.redis.enabled, true)
  }
  redis_keys = ["REDIS_HOST", "REDIS_PORT", "REDIS_PASSWORD", "REDIS_URL"]
}

ephemeral "random_password" "redis" {
  for_each = local.redis
  length   = 32
  # Letters and digits are safe in REDIS_URL without escaping.
  special = false
}

resource "vault_kv_secret_v2" "redis_password" {
  for_each = local.redis
  mount    = "secret"
  name     = "${local.secret_path[each.key]}/redis-password"
  data_json_wo = jsonencode({
    password = ephemeral.random_password.redis[each.key].result
  })
  # Written once. Changing only OpenBao would leave Redis using its old password.
  data_json_wo_version = 1

  lifecycle {
    prevent_destroy = true
  }
}

ephemeral "vault_kv_secret_v2" "redis_password" {
  for_each = local.redis
  mount    = "secret"
  name     = vault_kv_secret_v2.redis_password[each.key].name

  depends_on = [vault_kv_secret_v2.redis_password]
}

resource "dokploy_redis" "this" {
  for_each        = local.redis
  name            = "${var.name}-redis"
  app_name_prefix = "${var.name}-${each.key}-redis"
  environment_id  = local.environment_ids[each.key]
  docker_image    = try(each.value.image, "redis:7-alpine")

  database_password_wo         = ephemeral.vault_kv_secret_v2.redis_password[each.key].data.password
  database_password_wo_version = 1

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # Hash only non-secret settings so a new host rewrites the app-facing secret without exposing values.
  redis_settings = {
    for e, _ in local.redis : e => {
      REDIS_HOST = dokploy_redis.this[e].app_name
      REDIS_PORT = "6379"
    }
  }
}

resource "vault_kv_secret_v2" "redis" {
  for_each = local.redis
  mount    = "secret"
  name     = "${local.secret_path[each.key]}/redis"
  data_json_wo = jsonencode(merge(local.redis_settings[each.key], {
    REDIS_PASSWORD = ephemeral.vault_kv_secret_v2.redis_password[each.key].data.password
    REDIS_URL = format("redis://:%s@%s:%s",
      ephemeral.vault_kv_secret_v2.redis_password[each.key].data.password,
      local.redis_settings[each.key].REDIS_HOST,
      local.redis_settings[each.key].REDIS_PORT,
    )
  }))
  data_json_wo_version = parseint(substr(sha256(jsonencode(local.redis_settings[each.key])), 0, 8), 16)

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  env_lines = {
    for e, c in local.environments : e => join("\n", concat(
      [for k in sort(keys(c.env)) : "${k}=${c.env[k]}"],
      [for k in c.secrets :
      "${k}=$${{vault.${local.provider_name[e]}.${local.secret_path[e]}:${k}}}"],
      flatten([for name, ks in c.shared : [for k in ks :
      "${k}=$${{vault.${local.provider_name[e]}.shared/${name}/${e}:${k}}}"]]),
      [for k in(contains(keys(local.redis), e) ? local.redis_keys : []) :
      "${k}=$${{vault.${local.provider_name[e]}.${local.secret_path[e]}/redis:${k}}}"],
    ))
  }
}

resource "dokploy_application" "this" {
  for_each        = local.environments
  name            = var.name
  app_name_prefix = "${var.name}-${each.key}"
  environment_id  = local.environment_ids[each.key]

  # The exact image, tag@digest, from release.yaml (public on GHCR: no registry credentials). Until it
  # names one, a placeholder that's never deployed.
  docker = {
    image = coalesce(each.value.image, "${local.image}:not-deployed")
  }

  env             = local.env_lines[each.key]
  create_env_file = false
  # Never on its own (no webhook deploys). Only through this repo, and only once there's an image: the
  # change from the placeholder to the first image is the first deploy, with the volumes already there.
  auto_deploy      = false
  deploy_on_change = each.value.image != null

  # Every Redis reference must exist before the application's first deployment.
  depends_on = [dokploy_vault_provider.this, vault_kv_secret_v2.redis]

  lifecycle {
    precondition {
      condition = each.value.image == null || (
        startswith(each.value.image, "${local.image}:") && can(regex("@sha256:[0-9a-f]{64}$", each.value.image))
      )
      error_message = "release.yaml's ${each.key} image must be ${local.image}:<tag>@sha256:<digest>, or null."
    }
  }
}

locals {
  volumes = merge([
    for e, c in local.environments : {
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

# One entry per environment and hostname, keyed "<env>:<host>" so that removing one domain never shifts
# another one's key.
locals {
  domains = merge([
    for e, c in local.environments : {
      for host, settings in c.domains : "${e}:${host}" => {
        env      = e
        host     = host
        settings = settings
      }
    }
  ]...)
}

# Every setting in project.yaml passes through. Anything left out is null, which means the provider's
# own default, except https (on) and certificate_type (Let's Encrypt when https is on).
resource "dokploy_domain" "this" {
  for_each = local.domains

  application_id       = dokploy_application.this[each.value.env].id
  host                 = each.value.host
  port                 = try(each.value.settings.port, null)
  https                = try(each.value.settings.https, true)
  certificate_type     = try(each.value.settings.certificate_type, try(each.value.settings.https, true) ? "letsencrypt" : "none")
  custom_cert_resolver = try(each.value.settings.custom_cert_resolver, null)
  custom_entrypoint    = try(each.value.settings.custom_entrypoint, null)
  path                 = try(each.value.settings.path, null)
  internal_path        = try(each.value.settings.internal_path, null)
  strip_path           = try(each.value.settings.strip_path, null)
  enabled              = try(each.value.settings.enabled, null)
  forward_auth_enabled = try(each.value.settings.forward_auth_enabled, null)

  lifecycle {
    precondition {
      condition     = try(each.value.settings.port, null) != null
      error_message = "project.yaml's ${each.value.env} domain ${each.value.host} needs a port: the container port Traefik forwards to."
    }
  }
}
