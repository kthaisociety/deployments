# `project.yaml` guide

Use this guide before writing or editing a project's configuration. For a new project, start with
the [project template](project.template.yaml). The local check validates project files, this guide,
and the template; run `scripts/check-project-yaml` before pushing.

## Top level

Every file has `repo`, `defaults`, and `environments`. `image` is optional; when omitted, the image
defaults to `ghcr.io/<repo>`. Every key is a string: quote one that YAML would read as a number,
boolean, null or date, such as `"8080"` or `"2024-01-01"`. The complete example below uses every key
the schema accepts.

```yaml
repo: kthaisociety/example-service
image: ghcr.io/example/other
defaults:
  env:
    PORT: "8000"
    GIN_MODE: release
    LOG_LEVEL: info
  secrets:
    - SESSION_SECRET
    - DATABASE_URL
    - REDIS_URL
  shared:
    - SHARED_TOKEN
  databases:
    postgres:
      image: postgres:17-alpine
      backups:
        schedule: "0 2 * * *"
        keep: 14
    redis:
      image: redis:7-alpine
  volumes:
    /data: app-data
environments:
  staging:
    env:
      LOG_LEVEL: debug
    domains:
      staging.example.kthais.com:
        port: 8000
        https: true
        certificate_type: custom
        custom_cert_resolver: myresolver
        path: /api
        internal_path: /
        strip_path: true
        enabled: true
        forward_auth_enabled: false
        custom_entrypoint: websecure
  production:
    domains:
      example.kthais.com:
        port: 8000
```

## Defaults

`defaults` provides values inherited by both environments. `env`, `secrets`, `shared` and
`databases` are required; write `{}` or `[]` when unused. `volumes` is optional and usually belongs in a database.

```yaml excerpt
defaults:
  env:
    PORT: "8000"
    GIN_MODE: release
    LOG_LEVEL: info
  secrets:
    - SESSION_SECRET
    - DATABASE_URL
    - REDIS_URL
  shared:
    - SHARED_TOKEN
  databases:
    postgres:
      image: postgres:17-alpine
      backups:
        schedule: "0 2 * * *"
        keep: 14
    redis:
      image: redis:7-alpine
  volumes:
    /data: app-data
```

## Env

`env` maps variable names to single-line strings. Quote numbers and booleans so YAML does not change
their values. Environment values override defaults with the same name. A name belongs to only one of
`env`, `secrets` and `shared`, checked per environment after its `env` is merged over the defaults.

```yaml excerpt
  env:
    PORT: "8000"
    GIN_MODE: release
    LOG_LEVEL: info
```

## Secrets

`secrets` lists secret names required by the project. Put the names here once; values for each
environment live in OpenBao, at `secret/<project>/<environment>`. A name that one of the project's
[databases](#databases) writes, such as `DATABASE_URL`, reads that database's credentials instead.

```yaml excerpt
  secrets:
    - SESSION_SECRET
    - DATABASE_URL
    - REDIS_URL
```

## Shared secrets

`shared` lists the names a project reads from the shared store, `secret/shared/<environment>` in
OpenBao. Every project can read the shared store for its own environment, so list only the names you
use. To add a new shared value, ask an infra admin to set it in the OpenBao UI.

```yaml excerpt
  shared:
    - SHARED_TOKEN
```

## Databases

`databases` gives each environment its own database for every engine listed, `postgres` and `redis`.
It sits under `defaults` only: the code relies on it, so staging and production have the same
engines, each with its own instance and credentials. `image` is optional and replaces the default
image (`postgres:17-alpine`, `redis:7-alpine`).

The pipeline generates every credential and writes it to OpenBao at
`secret/<project>/<environment>/database/<engine>`. Nobody sees or types it. The app gets a setting
only when its name is listed in `secrets`, so `project.yaml` shows everything the app reads. List the
ones the app's client reads:

| Engine | Names it writes |
|---|---|
| `postgres` | `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `DATABASE_URL` |
| `redis` | `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `REDIS_URL` |

libpq and pgx read the `PG*` names with no configuration. The check fails on a listed name whose
engine isn't under `databases`, on an engine with none of its names listed, and on an engine's name
in `env` or `shared`.

Removing an engine, or the project, fails the plan instead of deleting the data. Deleting a database
is a deliberate change of its own, reviewed by Platform.

Production's Postgres is backed up to GleSYS object storage with nothing to add here: every day at
00:00 UTC (`0 0 * * *`), keeping the last 30 dumps. `backups` under `postgres` changes that for the
project: `schedule` is five cron fields (minute, hour, day of month, month, day of week) in UTC,
quoted, and `keep` is how many dumps to keep, at least 7. Either can be left out and keeps its
default; backups can't be turned off. Staging and Redis aren't backed up. Restoring one is in
infrastructure's [database backups guide](https://github.com/kthaisociety/infrastructure/blob/main/docs/database-backups.md).

```yaml excerpt
  databases:
    postgres:
      image: postgres:17-alpine
      backups:
        schedule: "0 2 * * *"
        keep: 14
    redis:
      image: redis:7-alpine
```

## Volumes

`volumes` maps a container path to its volume name. It is optional, and stateful data is usually
better kept in a database.

```yaml excerpt
  volumes:
    /data: app-data
```

## Environments

Every project has exactly `staging` and `production`. Either may be `{}` when it has no overrides.
Every environment also needs a corresponding line in that project's `release.yaml`.

```yaml excerpt
environments:
  staging:
    env:
      LOG_LEVEL: debug
    domains:
      staging.example.kthais.com:
        port: 8000
        https: true
        certificate_type: custom
        custom_cert_resolver: myresolver
        path: /api
        internal_path: /
        strip_path: true
        enabled: true
        forward_auth_enabled: false
        custom_entrypoint: websecure
  production:
    domains:
      example.kthais.com:
        port: 8000
```

## Domains

`domains` is optional under each environment and is keyed by hostname. `port` is required and must
be from 1 to 65535. Certificate settings must agree: `certificate_type` is `letsencrypt`, `none`,
or `custom`; custom certificates need `custom_cert_resolver`; `https: false` permits only
`certificate_type: none`. `path` and `internal_path` start with `/`. A host and path belong to one
domain across every project and environment, so staging and production need different hosts. Hosts
compare without case, and a domain with no `path` is at `/`. The same host on another `path` is fine.

```yaml excerpt
    domains:
      staging.example.kthais.com:
        port: 8000
        https: true
        certificate_type: custom
        custom_cert_resolver: myresolver
        path: /api
        internal_path: /
        strip_path: true
        enabled: true
        forward_auth_enabled: false
        custom_entrypoint: websecure
```
