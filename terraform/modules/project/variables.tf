variable "name" {
  description = "Project name: its folder under projects/."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.name)) && !contains(["infrastructure", "shared"], var.name)
    error_message = "Project names are lowercase letters, digits and single hyphens, and not \"infrastructure\" or \"shared\"."
  }
}

variable "config" {
  description = "The decoded project.yaml."
  type        = any
  validation {
    condition     = alltrue([for e in keys(var.config.environments) : can(regex("^[a-z0-9]+$", e))])
    error_message = "Environment names are lowercase letters and digits only, no hyphens: <project>-<environment> must split at the last hyphen."
  }
}

variable "release" {
  description = "The decoded release.yaml: per environment, the image it runs (<image>:<tag>@sha256:<digest>), or null."
  type        = any
}
