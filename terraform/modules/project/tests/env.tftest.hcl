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
