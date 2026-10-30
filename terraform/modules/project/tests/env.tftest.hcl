# The app's env: plain values, then one OpenBao reference per secret name and per shared name. Mock
# providers, as in domains.tftest.hcl.

mock_provider "vault" {}
mock_provider "dokploy" {
  mock_resource "dokploy_application" {
    defaults = { id = "app-id" }
  }
}

variables {
  name    = "demo"
  release = { staging = null }
}

run "shared_names_read_the_environment_shared_store" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        env     = { MODE = "release" }
        secrets = ["TOKEN"]
        shared  = ["SHARED_TOKEN"]
      }
      environments = { staging = {} }
    }
  }

  assert {
    condition = dokploy_application.this["staging"].env == join("\n", [
      "MODE=release",
      "TOKEN=$${{vault.demo-staging.demo/staging:TOKEN}}",
      "SHARED_TOKEN=$${{vault.demo-staging.shared/staging:SHARED_TOKEN}}",
    ])
    error_message = "A shared name should read secret/shared/<env>, after the plain values and the secrets."
  }
}

run "storage_names_read_the_storage_secret" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        env     = {}
        secrets = ["TOKEN", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "S3_ENDPOINT", "S3_REGION", "S3_BUCKET"]
        shared  = []
      }
      environments = { staging = {} }
    }
  }

  assert {
    condition = dokploy_application.this["staging"].env == join("\n", [
      "TOKEN=$${{vault.demo-staging.demo/staging:TOKEN}}",
      "S3_ACCESS_KEY_ID=$${{vault.demo-staging.demo/staging/storage:S3_ACCESS_KEY_ID}}",
      "S3_SECRET_ACCESS_KEY=$${{vault.demo-staging.demo/staging/storage:S3_SECRET_ACCESS_KEY}}",
      "S3_ENDPOINT=$${{vault.demo-staging.demo/staging/storage:S3_ENDPOINT}}",
      "S3_REGION=$${{vault.demo-staging.demo/staging/storage:S3_REGION}}",
      "S3_BUCKET=$${{vault.demo-staging.demo/staging/storage:S3_BUCKET}}",
    ])
    error_message = "The storage names should read secret/<project>/<env>/storage; other names the app's own path."
  }
}

run "bucket_names_read_the_storage_secret" {
  command = plan

  variables {
    config = {
      repo = "example/demo"
      defaults = {
        env = {}
        # The last two aren't S3_BUCKET_<NAME>: they read the app's own path.
        secrets = ["S3_BUCKET_UPLOADS", "S3_BUCKET_USER_FILES", "S3_BUCKET_", "S3_BUCKETS"]
        shared  = []
      }
      environments = { staging = {} }
    }
  }

  assert {
    condition = dokploy_application.this["staging"].env == join("\n", [
      "S3_BUCKET_UPLOADS=$${{vault.demo-staging.demo/staging/storage:S3_BUCKET_UPLOADS}}",
      "S3_BUCKET_USER_FILES=$${{vault.demo-staging.demo/staging/storage:S3_BUCKET_USER_FILES}}",
      "S3_BUCKET_=$${{vault.demo-staging.demo/staging:S3_BUCKET_}}",
      "S3_BUCKETS=$${{vault.demo-staging.demo/staging:S3_BUCKETS}}",
    ])
    error_message = "S3_BUCKET_<NAME> should read secret/<project>/<env>/storage, like S3_BUCKET."
  }
}

run "storage_name_in_env_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { env = { S3_BUCKET = "my-bucket" } }
      environments = { staging = {} }
    }
  }

  expect_failures = [var.config]
}

run "storage_name_in_an_environments_env_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = {}
      environments = { staging = { env = { S3_ENDPOINT = "https://elsewhere" } } }
    }
  }

  expect_failures = [var.config]
}

run "bucket_name_in_env_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { env = { S3_BUCKET_UPLOADS = "my-bucket" } }
      environments = { staging = {} }
    }
  }

  expect_failures = [var.config]
}

run "storage_name_in_shared_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { shared = ["S3_ACCESS_KEY_ID"] }
      environments = { staging = {} }
    }
  }

  expect_failures = [var.config]
}
