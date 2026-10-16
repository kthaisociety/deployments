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
  validation {
    condition     = try(var.config.defaults.domains, null) == null
    error_message = "Domains go under each environment, not defaults: a default domain would put the same host on every environment."
  }
  # A misspelt setting would otherwise be ignored and quietly fall back to its default.
  validation {
    condition = alltrue(flatten([
      for e, c in var.config.environments : [
        for host, s in try(c.domains, {}) : [
          for k in try(keys(s), []) : contains([
            "port", "https", "certificate_type", "custom_cert_resolver", "path", "internal_path",
            "strip_path", "enabled", "forward_auth_enabled", "custom_entrypoint",
          ], k)
        ]
      ]
    ]))
    error_message = "A domain in project.yaml has an unknown setting. Allowed: port, https, certificate_type, custom_cert_resolver, path, internal_path, strip_path, enabled, forward_auth_enabled, custom_entrypoint."
  }
  validation {
    condition = alltrue(flatten([
      for c in concat([try(var.config.defaults, {})], values(var.config.environments)) : [
        for k in try(keys(c.redis), []) : contains(["enabled", "image"], k)
      ]
    ]))
    error_message = "redis in project.yaml has an unknown setting. Allowed: enabled, image."
  }
  validation {
    condition = alltrue([
      for c in concat([try(var.config.defaults, {})], values(var.config.environments)) :
      try(c.redis, null) == null ? true : can(keys(c.redis))
    ])
    error_message = "redis in project.yaml must be a settings map, for example redis: {enabled: true}."
  }
  validation {
    condition = alltrue([
      for c in concat([try(var.config.defaults, {})], values(var.config.environments)) :
      try(c.redis.enabled, true) == true || try(c.redis.enabled, true) == false
    ])
    error_message = "redis.enabled in project.yaml must be true or false."
  }
  validation {
    condition = alltrue([
      for c in concat([try(var.config.defaults, {})], values(var.config.environments)) :
      !can(c.redis.image) ? true : try(c.redis.image == tostring(c.redis.image) && trimspace(c.redis.image) != "", false)
    ])
    error_message = "redis.image in project.yaml must be a non-empty image name."
  }
}

variable "release" {
  description = "The decoded release.yaml: per environment, the image it runs (<image>:<tag>@sha256:<digest>), or null."
  type        = any
}
