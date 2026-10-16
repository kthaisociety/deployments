# deployments

What every KTHAIS project runs: its Dokploy project, its OpenBao secrets wiring, and the exact image of
each environment. Merging here is deploying.

The design is in
[kthaisociety/infrastructure: docs/delivery-plan.md](https://github.com/kthaisociety/infrastructure/blob/main/docs/delivery-plan.md),
the step-by-step guide in
[docs/app-delivery.md](https://github.com/kthaisociety/infrastructure/blob/main/docs/app-delivery.md).
`infrastructure` holds the platform underneath (OpenBao, Dokploy core, storage); this repo holds the
projects on top of it.

## Layout

```
projects/<project>/
  project.yaml    # config, secret names, environments (staging, production)
  release.yaml    # the image each environment runs, tag@digest; written by the deploy bot
terraform/        # one OpenTofu root: OpenBao (provider tokens) and Dokploy
  modules/project/  # a project's Dokploy side: project, environments, vault providers, apps, volumes, domains, Redis
.github/workflows/
  pr.yml          # PR title
  tofu.yml        # checks and plan on PRs; apply on main, weekly and by hand
  deploy.yml      # deploy requests: validate, commit the release.yaml line, apply, report (one run)
```

A project's OpenBao side (its policies and empty secret paths) lives in
[kthaisociety/infrastructure](https://github.com/kthaisociety/infrastructure)'s `terraform/openbao`:
policies decide what a token can read, so this repo's CI can't write them. It mints provider tokens and,
once the database policy is applied, writes generated Redis credentials to the paths below.

## Adding a project

1. `infrastructure`: one line in `terraform/openbao/projects.yaml`, `my-app: {}` (staging and
   production; add `shared: [...]` if it reads shared secrets). That creates its policies and empty
   secret paths. This repo's `check` fails, with that line, until it's there.
2. Write its secrets in OpenBao (`secret/<project>/<environment>`).
3. Here, one PR: `projects/<project>/project.yaml`; `projects/<project>/release.yaml` with every
   environment `null`; and the project added to the `project` options in `.github/workflows/deploy.yml`
   (the dropdown; `check` fails if it's missing). Merging creates the Dokploy project, environments, vault
   providers, and each environment's app and volumes, not deployed.
4. Deploy with the deploy workflow (or the app repo's `deploy-staging` job). From then on only the deploy
   workflow changes `release.yaml`.

## Adding a domain

1. In `projects/<project>/project.yaml`, under the environment (never `defaults`): `domains:`, keyed by
   hostname. `port` (the container port Traefik forwards to) is required. Optional: `https`,
   `certificate_type`, `custom_cert_resolver`, `path`, `internal_path`, `strip_path`, `enabled`,
   `forward_auth_enabled`, `custom_entrypoint`.
2. Left out: HTTPS on, with a Let's Encrypt certificate; everything else is Dokploy's default. A
   misspelt setting fails the plan instead of being ignored.
3. Merging creates the domain in Dokploy. Removing its lines removes it; other domains are untouched.

## Adding Redis

Declare Redis under `defaults` for every environment, or under one environment. Only `enabled` and
`image` are accepted. Settings merge from defaults to the environment; an omitted block in both means
no Redis. An empty map enables it too, matching the Postgres design in
[deployments#17](https://github.com/kthaisociety/deployments/pull/17).

```yaml
defaults:
  redis: {enabled: true, image: "redis:7-alpine"}
environments:
  staging:
    redis: {image: "redis:7.4-alpine"}  # overrides only the image
  production:
    redis: {enabled: false}             # does not create Redis in this environment
```

For just staging, leave Redis out of `defaults` and add `redis: {enabled: true}` to `staging`.
`enabled` defaults to `true`, and `image` defaults to `redis:7-alpine`. Each selected environment gets
its own internal Dokploy Redis service, with prefix `<project>-<env>-redis`; port 6379 stays internal.

The app reads `REDIS_URL`, or the individual `REDIS_HOST`, `REDIS_PORT` and `REDIS_PASSWORD` settings.
Do not add these to `env` or `secrets`: the module adds all four as references to
`secret/<project>/<env>/redis`. The generated password is stored separately, once, at
`secret/<project>/<env>/redis-password` and read back before being sent to Redis. Generated credentials
only pass through ephemeral sources and write-only fields, so their values do not enter git, plans,
state or the app's configured env in Dokploy. The running app resolves the references when deployed.
Redis's host name also appears in the `projects` output under `apps.<env>.redis`.

Redis and both secrets have `prevent_destroy`. Removing or disabling Redis after creation fails the
plan; deletion requires an explicitly reviewed `removed` block. Password rotation is not implemented:
do not bump either write-only password version independently.

**Before merging:** the OpenBao policy must allow deployments CI to write/read the two Redis paths
and `dokploy-project-<project>-<env>` to read the app-facing secret. As reviewed at commit `0abcd8f`,
[infrastructure#25](https://github.com/kthaisociety/infrastructure/pull/25) only grants
`secret/<project>/<env>/database/*`; it does not cover these `/redis` and `/redis-password` paths.
Align and apply the policies before merging this implementation. Postgres remains separate work in
PR #17; this branch adds Redis only.

## Rules

- Everything changes by PR, squash-merged, with a Conventional Commit title, and a code owner's approval.
- Except `release.yaml`: only the deploy workflow changes it (it commits the line to `main` as
  `kthais-deploy` and applies in the same run). PRs that edit an existing `release.yaml` fail `check`.
- Public by design: no secret value is ever in this repo. Values live in OpenBao.

## Deploying

- **Automatically**, from an app repo that has opted in (a `request-deploy` job in its `build.yml` for
  staging, in its `release.yml` for production): its CI starts `deploy.yml` here with the project,
  environment and tag, and waits for the result.
- **By hand**: Actions → deploy → Run workflow: pick the project and environment from the dropdowns,
  type the tag (`sha-<7>` or `X.Y.Z`). **Rolling back is the same**, with a previous tag.

One run does the whole deploy:
1. Validate the request, and look up the tag's digest in GHCR. For production: the tag must be a
   release (`X.Y.Z` with a GitHub Release), built from the release commit.
2. Commit the one `release.yaml` line to `main` as `kthais-deploy` (signed by GitHub), unless it's already
   there.
3. `tofu apply` `main`, in the same run, and report the result.

Applies (deploys and `tofu` runs) go one at a time. If two more requests arrive while one runs, the older
waiting one is cancelled by GitHub; its caller sees "cancelled" and can re-run it.
