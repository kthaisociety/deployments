# The staging gate (staging_gate.tf): basic auth on staging unless private: false, never on production.
# Mock providers: no OpenBao, no Dokploy, no secrets, so the check job runs these on every PR.

mock_provider "vault" {
  mock_data "vault_generic_secret" {
    defaults = { data_json = "{\"current_version\":3}" }
  }
}
# Plan only: a mock apply fails on dokploy_vault_provider's write-only token_wo. The app's id is fixed so
# a plan knows it.
mock_provider "dokploy" {
  mock_resource "dokploy_application" {
    defaults = { id = "app-id" }
  }
}

variables {
  name    = "demo"
  release = { staging = null, production = null }
}

run "staging_is_gated_by_default" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = {}, production = {} }
    }
  }

  assert {
    condition     = keys(dokploy_security.staging_gate) == ["staging"]
    error_message = "Staging, and only staging, should get the gate."
  }
  assert {
    condition     = dokploy_security.staging_gate["staging"].application_id == "app-id"
    error_message = "The gate should be on staging's app."
  }
  assert {
    condition     = dokploy_security.staging_gate["staging"].username == "kthais"
    error_message = "The gate's username should be kthais."
  }
  assert {
    condition     = dokploy_security.staging_gate["staging"].password_wo_version == 3
    error_message = "The password's version should be the OpenBao secret's current version, so a new one is sent."
  }
}

run "private_true_is_the_default" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { private = true }, production = {} }
    }
  }

  assert {
    condition     = length(dokploy_security.staging_gate) == 1
    error_message = "private: true should gate staging."
  }
}

run "private_false_leaves_staging_open" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { private = false }, production = {} }
    }
  }

  assert {
    condition     = length(dokploy_security.staging_gate) == 0
    error_message = "private: false should leave staging without the gate."
  }
  assert {
    condition     = length(data.vault_generic_secret.staging_gate_metadata) == 0
    error_message = "With no gated environment, the password shouldn't be read at all."
  }
}

run "private_under_production_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = {}, production = { private = true } }
    }
  }

  expect_failures = [var.config]
}

run "private_must_be_a_boolean" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { private = "no" }, production = {} }
    }
  }

  expect_failures = [var.config]
}

run "no_password_in_openbao_fails_the_plan" {
  command = plan

  override_data {
    target = data.vault_generic_secret.staging_gate_metadata
    values = { data_json = "{\"current_version\":0}" }
  }

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = {}, production = {} }
    }
  }

  expect_failures = [data.vault_generic_secret.staging_gate_metadata[0]]
}
