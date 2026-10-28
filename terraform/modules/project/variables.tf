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
  # Databases (databases.tf). What the code relies on is the same everywhere, so only under defaults.
  validation {
    condition     = alltrue([for e, c in var.config.environments : try(c.databases, null) == null])
    error_message = "databases go under defaults, not under an environment: staging and production each get their own, with the same engines."
  }
  validation {
    condition     = alltrue([for engine in keys(try(var.config.defaults.databases, {})) : contains(keys(local.database_keys), engine)])
    error_message = "databases in project.yaml has an unknown engine. Allowed: ${join(", ", keys(local.database_keys))}."
  }
  validation {
    condition = alltrue(flatten([
      for engine, s in try(var.config.defaults.databases, {}) : [
        can(keys(s)) || s == null ? true : false,
        [for k in try(keys(s), []) : contains(engine == "postgres" ? ["image", "backups"] : ["image"], k)],
      ]
    ]))
    error_message = "A database in project.yaml has an unknown setting, or isn't a map. Allowed: image, and backups for postgres. Write {} for none."
  }
  # Production's Postgres is always backed up (databases.tf): backups only changes when, and how many
  # dumps are kept.
  validation {
    condition = alltrue([
      for b in [try(var.config.defaults.databases.postgres.backups, null)] : b == null || (
        can(keys(b)) && alltrue([for k in try(keys(b), []) : contains(["schedule", "keep"], k)])
      )
    ])
    error_message = "databases.postgres.backups in project.yaml has an unknown setting, or isn't a map. Allowed: schedule, keep."
  }
  validation {
    condition = alltrue([
      for s in [try(var.config.defaults.databases.postgres.backups.schedule, null)] :
      s == null || can(regex("^[0-9*,/-]+( [0-9*,/-]+){4}$", s))
    ])
    error_message = "databases.postgres.backups.schedule in project.yaml must be a cron schedule: five fields of numbers, * , / and -, such as \"0 2 * * *\"."
  }
  # At least 7: with a frequent schedule, fewer can replace the last good dump within hours.
  validation {
    condition = alltrue([
      for n in [try(var.config.defaults.databases.postgres.backups.keep, null)] :
      n == null || try(n >= 7 && floor(n) == n, false)
    ])
    error_message = "databases.postgres.backups.keep in project.yaml must be a whole number of at least 7: how many dumps to keep."
  }
  # The app gets a database setting only by listing it in secrets. A name an engine writes must not
  # quietly read secret/<project>/<env> because its engine is missing, and an engine nobody reads is a
  # mistake.
  validation {
    condition = alltrue(flatten([
      for engine, ks in local.database_keys : [
        for k in ks : contains(keys(try(var.config.defaults.databases, {})), engine) || alltrue([
          for c in concat([try(var.config.defaults, {})], values(var.config.environments)) : !contains(try(c.secrets, []), k)
        ])
      ]
    ]))
    error_message = "secrets in project.yaml lists a name a database writes (${join(", ", flatten(values(local.database_keys)))}), but its engine isn't under defaults.databases. Add the engine, or rename the secret."
  }
  validation {
    condition = alltrue([
      for engine in keys(try(var.config.defaults.databases, {})) : anytrue([
        for k in try(local.database_keys[engine], []) : contains(try(var.config.defaults.secrets, []), k)
      ])
    ])
    error_message = "A database under defaults.databases has none of its settings in defaults.secrets, so the app can't reach it. List the ones it reads: ${join("; ", [for engine, ks in local.database_keys : "${engine}: ${join(", ", ks)}"])}."
  }
  # An enabled engine's name in env or shared would give the app that value instead of the database's.
  validation {
    condition = alltrue(flatten([
      for engine in keys(try(var.config.defaults.databases, {})) : [
        for c in concat([try(var.config.defaults, {})], values(var.config.environments)) : [
          for k in try(local.database_keys[engine], []) :
          !contains(keys(try(c.env, {})), k) && !contains(try(c.shared, []), k)
        ]
      ]
    ]))
    error_message = "env or shared in project.yaml sets a name an enabled database writes. List it in defaults.secrets instead: the app gets it from the database's secret in OpenBao."
  }
}

variable "release" {
  description = "The decoded release.yaml: per environment, the image it runs (<image>:<tag>@sha256:<digest>), or null."
  type        = any
}
