variable "state_passphrase" {
  description = "Passphrase for this repo's state and plan encryption. Not infrastructure's. Set via TF_VAR_state_passphrase."
  type        = string
  sensitive   = true
}

variable "openbao_jwt" {
  description = "GitHub Actions OIDC token with audience https://bao.kthais.com. Set by the tofu workflow."
  type        = string
  sensitive   = true
  ephemeral   = true
}
