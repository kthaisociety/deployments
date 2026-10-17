# The domain defaults and rejection rules README.md promises. Mock providers: no OpenBao, no Dokploy,
# no secrets, so the check job runs these on every PR.

mock_provider "vault" {}
mock_provider "random" {}
mock_provider "tls" {}
# Plan only: a mock apply fails on dokploy_vault_provider's write-only token_wo. The app's id is fixed so
# a plan knows it.
mock_provider "dokploy" {
  mock_resource "dokploy_application" {
    defaults = { id = "app-id" }
  }
}

variables {
  name    = "demo"
  release = { staging = null }
}

run "port_only_domain_gets_https_and_letsencrypt" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { domains = { "demo.test" = { port = 3000 } } } }
    }
  }

  assert {
    condition     = dokploy_domain.this["staging:demo.test"].https == true
    error_message = "A domain without https should have HTTPS on."
  }
  assert {
    condition     = dokploy_domain.this["staging:demo.test"].certificate_type == "letsencrypt"
    error_message = "A domain without certificate_type should get a Let's Encrypt certificate."
  }
  assert {
    condition     = dokploy_domain.this["staging:demo.test"].application_id == "app-id"
    error_message = "A domain should route to the environment's app."
  }
}

run "https_off_means_no_certificate" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { domains = { "demo.test" = { port = 3000, https = false } } } }
    }
  }

  assert {
    condition     = dokploy_domain.this["staging:demo.test"].https == false
    error_message = "https: false should turn HTTPS off."
  }
  assert {
    condition     = dokploy_domain.this["staging:demo.test"].certificate_type == "none"
    error_message = "https: false without certificate_type should mean no certificate."
  }
}

run "domain_under_defaults_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      defaults     = { domains = { "demo.test" = { port = 3000 } } }
      environments = { staging = {} }
    }
  }

  expect_failures = [var.config]
}

run "unknown_setting_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { domains = { "demo.test" = { port = 3000, htps = false } } } }
    }
  }

  expect_failures = [var.config]
}

run "missing_port_is_rejected" {
  command = plan

  variables {
    config = {
      repo         = "example/demo"
      environments = { staging = { domains = { "demo.test" = { https = true } } } }
    }
  }

  expect_failures = [dokploy_domain.this]
}
