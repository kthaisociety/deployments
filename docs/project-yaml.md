# `project.yaml` guide

Use this guide before writing or editing a project's configuration. For a new project, start with
the [project template](project.template.yaml). The local check validates project files, this guide,
and the template; run `scripts/check-project-yaml` before pushing.

## Top level

Every file has `repo`, `defaults`, and `environments`. `image` is optional; when omitted, the image
defaults to `ghcr.io/<repo>`. The complete example below uses every key the schema accepts.

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
  shared:
    shared-config:
      - SHARED_TOKEN
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

`defaults` provides values inherited by both environments. `env`, `secrets`, and `shared` are
required; write `{}` or `[]` when unused. `volumes` is optional and usually belongs in a database.

```yaml excerpt
defaults:
  env:
    PORT: "8000"
    GIN_MODE: release
    LOG_LEVEL: info
  secrets:
    - SESSION_SECRET
  shared:
    shared-config:
      - SHARED_TOKEN
  volumes:
    /data: app-data
```

## Env

`env` maps variable names to single-line strings. Quote numbers and booleans so YAML does not change
their values. Environment values override defaults with the same name.

```yaml excerpt
  env:
    PORT: "8000"
    GIN_MODE: release
    LOG_LEVEL: info
```

## Secrets

`secrets` lists secret names required by the project. Put the names here once; values for each
environment live in OpenBao.

```yaml excerpt
  secrets:
    - SESSION_SECRET
```

## Shared secrets

`shared` maps an OpenBao shared-secret group to the names it provides. The group and names are the
same for both environments; values live in OpenBao.

```yaml excerpt
  shared:
    shared-config:
      - SHARED_TOKEN
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
`certificate_type: none`. `path` and `internal_path` start with `/`.

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
