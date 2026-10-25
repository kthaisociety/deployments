# Databases (databases.tf): one instance per engine and environment, credentials only in OpenBao, a
# listed secret name reaching its engine's path, and production's Postgres backed up. Mock providers, as
# in domains.tftest.hcl.

mock_provider "vault" {}
mock_provider "random" {}
mock_provider "dokploy" {
  mock_resource "dokploy_project" {
    defaults = { production_environment_id = "production-id" }
  }
  mock_resource "dokploy_environment" {
    defaults = { id = "staging-id" }
  }
  mock_resource "dokploy_postgres" {
    defaults = { id = "postgres-id", app_name = "demo-env-postgres-abcdef" }
  }
  mock_resource "dokploy_redis" {
    defaults = { app_name = "demo-env-redis-abcdef" }
  }
  mock_data "dokploy_destination" {
    defaults = { id = "backups-id" }
  }
}

variables {
  name    = "demo"
  release = { staging = null, production = null }
}

run "no_databases_means_no_resources" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["TOKEN"], databases = {} }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition = (
      length(dokploy_postgres.this) == 0 && length(dokploy_redis.this) == 0 &&
      length(vault_kv_secret_v2.postgres_password) == 0 && length(vault_kv_secret_v2.redis_password) == 0 &&
      length(dokploy_backup.postgres) == 0 && length(data.dokploy_destination.database_backups) == 0
    )
    error_message = "Without databases, no database resources should exist, and no backup destination is looked up."
  }
}

run "every_environment_gets_its_own" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        secrets   = ["DATABASE_URL", "REDIS_URL"]
        databases = { postgres = {}, redis = { image = "redis:8-alpine" } }
      }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition = (
      keys(dokploy_postgres.this) == ["production", "staging"] &&
      keys(dokploy_redis.this) == ["production", "staging"] &&
      dokploy_postgres.this["staging"].environment_id == "staging-id" &&
      dokploy_postgres.this["production"].environment_id == "production-id" &&
      dokploy_postgres.this["staging"].app_name_prefix == "demo-staging-postgres" &&
      dokploy_redis.this["production"].app_name_prefix == "demo-production-redis"
    )
    error_message = "Each environment should get its own Postgres and Redis, in its own Dokploy environment."
  }

  assert {
    condition = (
      dokploy_postgres.this["staging"].docker_image == "postgres:17-alpine" &&
      dokploy_redis.this["staging"].docker_image == "redis:8-alpine" &&
      dokploy_postgres.this["staging"].external_port == null &&
      dokploy_redis.this["staging"].external_port == null
    )
    error_message = "Images default per engine and can be set; neither database gets a host port."
  }

  assert {
    condition = (
      vault_kv_secret_v2.postgres_password["staging"].name == "demo/staging/database/postgres-password" &&
      vault_kv_secret_v2.postgres["staging"].name == "demo/staging/database/postgres" &&
      vault_kv_secret_v2.redis_password["production"].name == "demo/production/database/redis-password" &&
      vault_kv_secret_v2.redis["production"].name == "demo/production/database/redis" &&
      vault_kv_secret_v2.postgres_password["staging"].data_json_wo_version == 1 &&
      dokploy_postgres.this["staging"].database_password_wo_version == 1
    )
    error_message = "Credentials go under secret/<project>/<env>/database/, the password written once."
  }
}

run "production_postgres_is_backed_up" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        secrets   = ["DATABASE_URL", "REDIS_URL"]
        databases = { postgres = {}, redis = {} }
      }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition = (
      keys(dokploy_backup.postgres) == ["production"] &&
      data.dokploy_destination.database_backups[0].name == "database-backups"
    )
    error_message = "Only production's Postgres should be backed up, to the database-backups destination."
  }

  assert {
    condition = (
      dokploy_backup.postgres["production"].service_id == "postgres-id" &&
      dokploy_backup.postgres["production"].service_type == "postgres" &&
      dokploy_backup.postgres["production"].database == "demo" &&
      dokploy_backup.postgres["production"].destination_id == "backups-id" &&
      dokploy_backup.postgres["production"].cron_expression == "0 0 */5 * *" &&
      dokploy_backup.postgres["production"].keep_latest_count == 30
    )
    error_message = "Without backups, the backup should dump production's database to the destination every fifth day, keeping 30."
  }
}

run "backups_sets_schedule_and_keep" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        secrets   = ["DATABASE_URL"]
        databases = { postgres = { backups = { schedule = "0 2 * * *", keep = 10 } } }
      }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition = (
      keys(dokploy_backup.postgres) == ["production"] &&
      dokploy_backup.postgres["production"].cron_expression == "0 2 * * *" &&
      dokploy_backup.postgres["production"].keep_latest_count == 10
    )
    error_message = "backups should set production's schedule and how many dumps are kept, and still not back up staging."
  }
}

run "backups_with_one_setting_keeps_the_other_default" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        secrets   = ["DATABASE_URL"]
        databases = { postgres = { backups = { keep = 7 } } }
      }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition = (
      dokploy_backup.postgres["production"].cron_expression == "0 0 */5 * *" &&
      dokploy_backup.postgres["production"].keep_latest_count == 7
    )
    error_message = "A setting left out of backups should keep its default."
  }
}

run "backups_under_redis_is_rejected" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        secrets   = ["REDIS_URL"]
        databases = { redis = { backups = { keep = 7 } } }
      }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "unknown_backups_setting_is_rejected" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        secrets   = ["DATABASE_URL"]
        databases = { postgres = { backups = { enabled = false } } }
      }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "malformed_schedule_is_rejected" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        secrets   = ["DATABASE_URL"]
        databases = { postgres = { backups = { schedule = "daily" } } }
      }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "keep_below_one_is_rejected" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        secrets   = ["DATABASE_URL"]
        databases = { postgres = { backups = { keep = 0 } } }
      }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "no_postgres_means_no_backup" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["REDIS_URL"], databases = { redis = {} } }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition     = length(dokploy_backup.postgres) == 0 && length(data.dokploy_destination.database_backups) == 0
    error_message = "Redis isn't backed up, and a project without Postgres doesn't need the destination to exist."
  }
}

run "postgres_identifiers_have_no_hyphens" {
  command = plan

  variables {
    name    = "demo-app"
    release = { staging = null }
    config = {
      repo         = "example/demo-app"
      defaults     = { secrets = ["PGHOST"], databases = { postgres = {} } }
      environments = { staging = {} }
    }
  }

  assert {
    condition = (
      dokploy_postgres.this["staging"].database_name == "demo_app" &&
      dokploy_postgres.this["staging"].database_user == "demo_app"
    )
    error_message = "Postgres database and user names should use underscores."
  }
}

run "listed_names_read_their_engines_path" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        env       = { MODE = "release" }
        secrets   = ["TOKEN", "DATABASE_URL", "PGHOST", "REDIS_URL"]
        shared    = ["SHARED_TOKEN"]
        databases = { postgres = {}, redis = {} }
      }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition = dokploy_application.this["staging"].env == join("\n", [
      "MODE=release",
      "TOKEN=$${{vault.demo-staging.demo/staging:TOKEN}}",
      "DATABASE_URL=$${{vault.demo-staging.demo/staging/database/postgres:DATABASE_URL}}",
      "PGHOST=$${{vault.demo-staging.demo/staging/database/postgres:PGHOST}}",
      "REDIS_URL=$${{vault.demo-staging.demo/staging/database/redis:REDIS_URL}}",
      "SHARED_TOKEN=$${{vault.demo-staging.shared/staging:SHARED_TOKEN}}",
    ])
    error_message = "A database name in secrets should read its engine's secret; others keep secret/<project>/<env>."
  }

  assert {
    condition     = strcontains(dokploy_application.this["production"].env, "DATABASE_URL=$${{vault.demo-production.demo/production/database/postgres:DATABASE_URL}}")
    error_message = "Production should read production's database secret."
  }
}

run "unlisted_settings_are_not_wired" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["REDIS_URL"], databases = { redis = {} } }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition     = dokploy_application.this["staging"].env == "REDIS_URL=$${{vault.demo-staging.demo/staging/database/redis:REDIS_URL}}"
    error_message = "Only listed names reach the app: REDIS_HOST, REDIS_PORT and REDIS_PASSWORD weren't listed."
  }
}

run "secret_values_follow_the_host" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["REDIS_URL"], databases = { redis = {} } }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition = vault_kv_secret_v2.redis["staging"].data_json_wo_version == parseint(substr(sha256(jsonencode({
      REDIS_HOST = "demo-env-redis-abcdef"
      REDIS_PORT = "6379"
    })), 0, 8), 16)
    error_message = "The app's secret is rewritten when the host or port changes, and only then."
  }
}

run "databases_under_an_environment_are_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["TOKEN"] }
      environments = { staging = { databases = { postgres = {} } }, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "unknown_engine_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["MONGODB_URI"], databases = { mongo = {} } }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "unknown_setting_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["DATABASE_URL"], databases = { postgres = { iamge = "postgres:16" } } }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "database_name_without_its_engine_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["DATABASE_URL", "REDIS_URL"], databases = { redis = {} } }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "engine_name_in_env_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { env = { DATABASE_URL = "old-url" }, secrets = ["PGHOST"], databases = { postgres = {} } }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "engine_name_in_an_environments_env_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["PGHOST"], databases = { postgres = {} } }
      environments = { staging = { env = { PGPASSWORD = "x" } }, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "engine_name_in_shared_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["REDIS_HOST"], shared = ["REDIS_URL"], databases = { redis = {} } }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "disabled_engines_name_in_env_is_allowed" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { env = { DATABASE_URL = "postgresql://elsewhere" }, databases = {} }
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition     = strcontains(dokploy_application.this["staging"].env, "DATABASE_URL=postgresql://elsewhere")
    error_message = "Without the engine, its names in env are ordinary values, such as an external database's URL."
  }
}

run "engine_without_a_listed_name_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { secrets = ["DATABASE_URL"], databases = { postgres = {}, redis = {} } }
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [var.config]
}
