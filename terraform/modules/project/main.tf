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
      source = "vanillauys/dokploy"
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
      # null: no database. {} or settings: one Postgres, the environment's settings on top of defaults'.
      postgres = (try(local.defaults.postgres, null) == null && try(c.postgres, null) == null ? null :
      merge(coalesce(try(local.defaults.postgres, null), {}), coalesce(try(c.postgres, null), {})))
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

# Per environment with `postgres`: a Postgres service, its password generated here and kept in OpenBao.
# The value is only ever ephemeral or write-only (*_wo), so it's in no plan, no state, no git and not in
# the app's env: the app gets every connection setting as a ${{vault.…}} reference to
# secret/<project>/<env>/postgres.
#
# Two secrets, because the host (the database's app_name, with Dokploy's random suffix) exists only once
# the database does, and the database needs its password first:
#   1. secret/<project>/<env>/postgres-password: the generated password, written once. The source of truth.
#   2. the database, created with that password, read back from OpenBao. Never straight from the
#      generator: if an apply fails between 1 and 2, the next one generates a different password, which
#      must not reach Dokploy.
#   3. secret/<project>/<env>/postgres: what the app reads, host and password included.
#
# prevent_destroy: removing `postgres` (or the project) fails the plan instead of deleting the data and
# its credentials. Deleting them is a deliberate `removed` block.
locals {
  postgres = { for e, c in local.environments : e => c.postgres if c.postgres != null }
  # Postgres identifiers: no hyphens.
  postgres_name = replace(var.name, "-", "_")
  postgres_keys = ["POSTGRES_HOST", "POSTGRES_PORT", "POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD", "DATABASE_URL"]
}

ephemeral "random_password" "postgres" {
  for_each = local.postgres
  length   = 32
  # Letters and digits: safe in DATABASE_URL without escaping.
  special = false
}

resource "vault_kv_secret_v2" "postgres_password" {
  for_each = local.postgres
  mount    = "secret"
  name     = "${local.secret_path[each.key]}/postgres-password"
  data_json_wo = jsonencode({
    password = ephemeral.random_password.postgres[each.key].result
  })
  # Written once. A new version would change only OpenBao, not the database.
  data_json_wo_version = 1

  lifecycle {
    prevent_destroy = true
  }
}

ephemeral "vault_kv_secret_v2" "postgres_password" {
  for_each = local.postgres
  mount    = "secret"
  name     = vault_kv_secret_v2.postgres_password[each.key].name

  # Opened at apply on the first run, once the secret exists.
  depends_on = [vault_kv_secret_v2.postgres_password]
}

resource "dokploy_postgres" "this" {
  for_each        = local.postgres
  name            = "${var.name}-db"
  app_name_prefix = "${var.name}-${each.key}-db"
  environment_id  = local.environment_ids[each.key]
  docker_image    = try(each.value.image, "postgres:17-alpine")
  database_name   = local.postgres_name
  database_user   = local.postgres_name

  # Postgres sets the password only when it initialises an empty volume, so it's sent once, at create.
  database_password_wo         = ephemeral.vault_kv_secret_v2.postgres_password[each.key].data.password
  database_password_wo_version = 1

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # The non-secret settings: a change to any (a recreated database's new host) rewrites the app's secret.
  postgres_settings = {
    for e, _ in local.postgres : e => {
      POSTGRES_HOST = dokploy_postgres.this[e].app_name
      POSTGRES_PORT = "5432"
      POSTGRES_DB   = dokploy_postgres.this[e].database_name
      POSTGRES_USER = dokploy_postgres.this[e].database_user
    }
  }
}

resource "vault_kv_secret_v2" "postgres" {
  for_each = local.postgres
  mount    = "secret"
  name     = "${local.secret_path[each.key]}/postgres"
  data_json_wo = jsonencode(merge(local.postgres_settings[each.key], {
    POSTGRES_PASSWORD = ephemeral.vault_kv_secret_v2.postgres_password[each.key].data.password
    DATABASE_URL = format("postgresql://%s:%s@%s:%s/%s",
      local.postgres_settings[each.key].POSTGRES_USER,
      ephemeral.vault_kv_secret_v2.postgres_password[each.key].data.password,
      local.postgres_settings[each.key].POSTGRES_HOST,
      local.postgres_settings[each.key].POSTGRES_PORT,
      local.postgres_settings[each.key].POSTGRES_DB,
    )
  }))
  data_json_wo_version = parseint(substr(sha256(jsonencode(local.postgres_settings[each.key])), 0, 8), 16)

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
      [for k in(c.postgres == null ? [] : local.postgres_keys) :
      "${k}=$${{vault.${local.provider_name[e]}.${local.secret_path[e]}/postgres:${k}}}"],
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

  # The database's secret too: the first deploy must find every key it references.
  depends_on = [dokploy_vault_provider.this, vault_kv_secret_v2.postgres]

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