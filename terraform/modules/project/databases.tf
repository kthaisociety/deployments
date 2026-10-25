# Databases: `databases` under defaults (never per environment: what the code relies on is the same in
# staging and production) gives each environment its own Postgres and/or Redis in Dokploy.
#
# The module generates each password, keeps it in OpenBao and never anywhere else: it's only ever
# ephemeral or write-only (*_wo), so it's in no plan, no state, no git and not in the app's env. Each
# engine writes its connection settings to secret/<project>/<env>/database/<engine>. They aren't wired
# into the app on their own: the app gets one only by listing its name in `secrets`, like any other
# secret, so project.yaml shows everything the app reads. A listed name that belongs to an enabled
# engine reads from that engine's path instead of secret/<project>/<env> (main.tf, env_lines).
#
# Two secrets per engine, because the host (the service's app_name, with Dokploy's random suffix) exists
# only once the service does, and the service needs its password first:
#   1. database/<engine>-password: the generated password, written once. The source of truth.
#   2. the service, created with that password read back from OpenBao. Never straight from the
#      generator: if an apply fails between 1 and 2, the next one generates a different password, which
#      must not reach Dokploy.
#   3. database/<engine>: what the app reads, host and password included.
# kthaisociety/infrastructure's deployments policy lets this repo's CI write database/* for each project
# environment, and each project's policy read its own.
#
# prevent_destroy: removing an engine (or the project) fails the plan instead of deleting the data and
# its credentials. Deleting them is a deliberate `removed` block, reviewed on its own.
#
# Backups: production's Postgres is dumped to GleSYS object storage, through the Dokploy destination
# kthaisociety/infrastructure keeps (its docs/database-backups.md, restoring included): every fifth day
# unless databases.postgres.backups sets its own schedule and how many dumps to keep. Staging isn't backed
# up, nor is Redis.

locals {
  databases = try(local.defaults.databases, {})

  # The settings each engine writes, under the names its clients already read: libpq and pgx read the
  # PG* names with no configuration.
  database_keys = {
    postgres = ["PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE", "DATABASE_URL"]
    redis    = ["REDIS_HOST", "REDIS_PORT", "REDIS_PASSWORD", "REDIS_URL"]
  }
  database_images = {
    postgres = "postgres:17-alpine"
    redis    = "redis:7-alpine"
  }

  # Name => engine, for the enabled engines only: where env_lines finds a listed secret.
  database_key_engine = merge([
    for engine, _ in local.databases : { for k in local.database_keys[engine] : k => engine }
  ]...)

  database_path = {
    for e, _ in local.environments : e => "${local.secret_path[e]}/database"
  }
  # Per environment, name => the secret it reads, for the names the enabled engines write. Every other
  # name in `secrets` reads secret/<project>/<env> (main.tf, env_lines).
  database_secret = {
    for e, _ in local.environments : e => {
      for k, engine in local.database_key_engine : k => "${local.database_path[e]}/${engine}"
    }
  }

  postgres = { for e, _ in local.environments : e => local.databases.postgres if contains(keys(local.databases), "postgres") }
  redis    = { for e, _ in local.environments : e => local.databases.redis if contains(keys(local.databases), "redis") }

  # Postgres identifiers: no hyphens.
  postgres_name = replace(var.name, "-", "_")
}

# Postgres

ephemeral "random_password" "postgres" {
  for_each = local.postgres
  length   = 32
  # Letters and digits: safe in DATABASE_URL without escaping.
  special = false
}

resource "vault_kv_secret_v2" "postgres_password" {
  for_each = local.postgres
  mount    = "secret"
  name     = "${local.database_path[each.key]}/postgres-password"
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
  name            = "${var.name}-postgres"
  app_name_prefix = "${var.name}-${each.key}-postgres"
  environment_id  = local.environment_ids[each.key]
  docker_image    = try(each.value.image, local.database_images.postgres)
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
  # The settings that aren't secret: a change to any (a recreated service's new host) rewrites the
  # app's secret.
  postgres_settings = {
    for e, _ in local.postgres : e => {
      PGHOST     = dokploy_postgres.this[e].app_name
      PGPORT     = "5432"
      PGUSER     = dokploy_postgres.this[e].database_user
      PGDATABASE = dokploy_postgres.this[e].database_name
    }
  }
}

resource "vault_kv_secret_v2" "postgres" {
  for_each = local.postgres
  mount    = "secret"
  name     = "${local.database_path[each.key]}/postgres"
  data_json_wo = jsonencode(merge(local.postgres_settings[each.key], {
    PGPASSWORD = ephemeral.vault_kv_secret_v2.postgres_password[each.key].data.password
    DATABASE_URL = format("postgresql://%s:%s@%s:%s/%s",
      local.postgres_settings[each.key].PGUSER,
      ephemeral.vault_kv_secret_v2.postgres_password[each.key].data.password,
      local.postgres_settings[each.key].PGHOST,
      local.postgres_settings[each.key].PGPORT,
      local.postgres_settings[each.key].PGDATABASE,
    )
  }))
  data_json_wo_version = parseint(substr(sha256(jsonencode(local.postgres_settings[each.key])), 0, 8), 16)

  lifecycle {
    prevent_destroy = true
  }
}

# Postgres backups

locals {
  # Production's, always: backups (schedule, keep) can change when and how many, not whether.
  postgres_backups = {
    for e, c in local.postgres : e => {
      # Every fifth day at 00:00 UTC (Dokploy's clock), like kthais-backend's: the 1st, 6th, ..., 26th
      # and 31st of each month. The last 30 kept: about five months.
      schedule = coalesce(try(c.backups.schedule, null), "0 0 */5 * *")
      keep     = coalesce(try(c.backups.keep, null), 30)
    } if e == "production"
  }
}

# kthaisociety/infrastructure's terraform/dokploy (core.tf) makes it, by this name. Looked up only by a
# project that needs it.
data "dokploy_destination" "database_backups" {
  count = length(local.postgres_backups) > 0 ? 1 : 0
  name  = "database-backups"
}

resource "dokploy_backup" "postgres" {
  for_each       = local.postgres_backups
  service_id     = dokploy_postgres.this[each.key].id
  service_type   = "postgres"
  database       = dokploy_postgres.this[each.key].database_name
  destination_id = data.dokploy_destination.database_backups[0].id
  # Dokploy keys each dump <app_name>/<prefix>/<timestamp>.sql.gz itself: "/" adds no folder.
  prefix            = "/"
  cron_expression   = each.value.schedule
  keep_latest_count = each.value.keep
}

# Redis: the same three steps.

ephemeral "random_password" "redis" {
  for_each = local.redis
  length   = 32
  # Letters and digits: safe in REDIS_URL without escaping.
  special = false
}

resource "vault_kv_secret_v2" "redis_password" {
  for_each = local.redis
  mount    = "secret"
  name     = "${local.database_path[each.key]}/redis-password"
  data_json_wo = jsonencode({
    password = ephemeral.random_password.redis[each.key].result
  })
  # Written once. A new version would change only OpenBao, not Redis.
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
  docker_image    = try(each.value.image, local.database_images.redis)

  database_password_wo         = ephemeral.vault_kv_secret_v2.redis_password[each.key].data.password
  database_password_wo_version = 1

  lifecycle {
    prevent_destroy = true
  }
}

locals {
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
  name     = "${local.database_path[each.key]}/redis"
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
