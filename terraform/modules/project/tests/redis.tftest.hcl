# Plan tests only. Mock providers exercise configuration and references without credentials or APIs.
mock_provider "vault" {}
mock_provider "random" {}
mock_provider "dokploy" {
  mock_resource "dokploy_project" {
    defaults = { production_environment_id = "production-id" }
  }
  mock_resource "dokploy_environment" {
    defaults = { id = "staging-id" }
  }
  mock_resource "dokploy_redis" {
    defaults = { app_name = "demo-staging-redis-abcdef" }
  }
}

variables {
  name    = "demo"
  release = { staging = null, production = null }
}

run "no_redis_means_no_resources_or_references" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = {}, production = {} }
    }
  }
  assert {
    condition = (
      length(dokploy_redis.this) == 0 &&
      length(vault_kv_secret_v2.redis_password) == 0 &&
      length(vault_kv_secret_v2.redis) == 0 &&
      alltrue([for a in dokploy_application.this : length(regexall("REDIS_", a.env)) == 0])
    )
    error_message = "Without Redis, neither its resources nor application references should exist."
  }
}

run "staging_only_redis_wires_all_four_references" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { redis = { enabled = true } }, production = {} }
    }
  }
  assert {
    condition = (
      keys(dokploy_redis.this) == ["staging"] &&
      keys(vault_kv_secret_v2.redis_password) == ["staging"] &&
      keys(vault_kv_secret_v2.redis) == ["staging"]
    )
    error_message = "Only staging should get Redis and its two secrets."
  }
  assert {
    condition = (
      dokploy_redis.this["staging"].name == "demo-redis" &&
      dokploy_redis.this["staging"].app_name_prefix == "demo-staging-redis" &&
      dokploy_redis.this["staging"].environment_id == "staging-id" &&
      dokploy_redis.this["staging"].docker_image == "redis:7-alpine" &&
      dokploy_redis.this["staging"].external_port == null
    )
    error_message = "Redis must use its environment's id, naming prefix and default internal image."
  }
  assert {
    condition = (
      vault_kv_secret_v2.redis_password["staging"].mount == "secret" &&
      vault_kv_secret_v2.redis_password["staging"].name == "demo/staging/redis-password" &&
      vault_kv_secret_v2.redis_password["staging"].data_json_wo_version == 1 &&
      dokploy_redis.this["staging"].database_password_wo_version == 1 &&
      vault_kv_secret_v2.redis["staging"].name == "demo/staging/redis"
    )
    error_message = "The stored password is written once, separate from the app-facing secret."
  }
  assert {
    condition = alltrue([
      for k in ["REDIS_HOST", "REDIS_PORT", "REDIS_PASSWORD", "REDIS_URL"] :
      contains(split("\n", dokploy_application.this["staging"].env),
      "${k}=$${{vault.demo-staging.demo/staging/redis:${k}}}")
    ]) && length(regexall("REDIS_", dokploy_application.this["production"].env)) == 0
    error_message = "All four staging values must be Vault references; production must get none."
  }
  assert {
    condition = vault_kv_secret_v2.redis["staging"].data_json_wo_version == parseint(substr(sha256(jsonencode({
      REDIS_HOST = "demo-staging-redis-abcdef"
      REDIS_PORT = "6379"
    })), 0, 8), 16)
    error_message = "The app-facing secret's version must depend on the non-secret host and port."
  }
}

run "empty_map_enables_redis" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { redis = {} }, production = {} }
    }
  }
  assert {
    condition     = keys(dokploy_redis.this) == ["staging"]
    error_message = "An empty Redis map should enable Redis, as in the Postgres design."
  }
}

run "defaults_merge_and_environment_image_override" {
  command = plan
  variables {
    config = {
      repo     = "example/demo"
      defaults = { redis = { enabled = true, image = "redis:7.4-alpine" } }
      environments = {
        staging    = { redis = { image = "redis:7.2-alpine" } }
        production = {}
      }
    }
  }
  assert {
    condition = (
      length(dokploy_redis.this) == 2 &&
      dokploy_redis.this["staging"].docker_image == "redis:7.2-alpine" &&
      dokploy_redis.this["production"].docker_image == "redis:7.4-alpine" &&
      dokploy_redis.this["production"].environment_id == "production-id" &&
      vault_kv_secret_v2.redis_password["production"].name == "demo/production/redis-password"
    )
    error_message = "Redis must inherit defaults, apply per-environment overrides and keep credentials separate."
  }
}

run "environment_can_disable_inherited_redis" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      defaults     = { redis = { enabled = true } }
      environments = { staging = {}, production = { redis = { enabled = false } } }
    }
  }
  assert {
    condition     = keys(dokploy_redis.this) == ["staging"] && dokploy_application.this["production"].env == ""
    error_message = "enabled: false must suppress inherited Redis and its application references."
  }
}

run "unknown_redis_setting_is_rejected" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { redis = { iamge = "redis:7-alpine" } }, production = {} }
    }
  }
  expect_failures = [var.config]
}

run "non_boolean_enabled_is_rejected" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { redis = { enabled = "true" } }, production = {} }
    }
  }
  expect_failures = [var.config]
}

run "environment_can_enable_disabled_default" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      defaults     = { redis = { enabled = false, image = "redis:7.4-alpine" } }
      environments = { staging = { redis = { enabled = true } }, production = {} }
    }
  }
  assert {
    condition     = keys(dokploy_redis.this) == ["staging"] && dokploy_redis.this["staging"].docker_image == "redis:7.4-alpine"
    error_message = "An environment can enable Redis while retaining its inherited image."
  }
}

run "null_redis_means_no_resources" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      defaults     = { redis = null }
      environments = { staging = { redis = null }, production = {} }
    }
  }
  assert {
    condition     = length(dokploy_redis.this) == 0
    error_message = "Null Redis without an inherited block should not create Redis."
  }
}

run "non_map_redis_is_rejected" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { redis = true }, production = {} }
    }
  }
  expect_failures = [var.config]
}

run "non_string_image_is_rejected" {
  command = plan
  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { redis = { image = [] } }, production = {} }
    }
  }
  expect_failures = [var.config]
}
