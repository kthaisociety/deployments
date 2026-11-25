# The staging gate (IT-97): basic auth in front of every staging domain, so only KTHAIS can use staging
# and search engines can't read or index it. Dokploy's security record covers every domain of the app,
# and staging and production are separate apps, so production is untouched.
#
# One password for all of staging, written by an infra admin at secret/shared/staging-gate (key
# `password`) and kept in 1Password as "Staging gate". kthaisociety/infrastructure lets this repo's CI
# read it (terraform/openbao/deployments.tf); apps can't. It never reaches the plan or state: the
# ephemeral read feeds password_wo. Its metadata's version number goes in the state instead, so writing a
# new version in OpenBao sends it to Dokploy at the next apply.
#
# `private: false` under staging in project.yaml leaves an app out, for one the gate would break.

locals {
  staging_gate = {
    for e, c in var.config.environments : e => e if e == "staging" && try(c.private, true)
  }
  staging_gate_path = "shared/staging-gate"
}

data "vault_generic_secret" "staging_gate_metadata" {
  count = length(local.staging_gate) > 0 ? 1 : 0
  path  = "secret/metadata/${local.staging_gate_path}"

  lifecycle {
    postcondition {
      condition     = try(jsondecode(self.data_json).current_version, 0) > 0
      error_message = "secret/${local.staging_gate_path} has no password yet. An infra admin writes it first (infrastructure's docs/app-delivery.md, 2.3)."
    }
  }
}

ephemeral "vault_kv_secret_v2" "staging_gate" {
  count = length(local.staging_gate) > 0 ? 1 : 0
  mount = "secret"
  name  = local.staging_gate_path

  # Opened once staging's app exists, like the database passwords: at apply on the app's first run, and
  # at plan after that. (It also keeps the mock-provider tests, which can't mock an ephemeral, at plan.)
  depends_on = [dokploy_application.this]
}

resource "dokploy_security" "staging_gate" {
  for_each       = local.staging_gate
  application_id = dokploy_application.this[each.key].id
  username       = "kthais"

  password_wo         = ephemeral.vault_kv_secret_v2.staging_gate[0].data.password
  password_wo_version = jsondecode(data.vault_generic_secret.staging_gate_metadata[0].data_json).current_version
}
