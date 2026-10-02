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
  modules/project/  # a project's Dokploy side: project, environments, vault providers, apps, volumes
.github/workflows/
  pr.yml          # PR title
  tofu.yml        # checks and plan on PRs; apply on main, weekly and by hand
  deploy.yml      # deploy requests from app repos: check, bot PR on release.yaml, merge, wait for the apply
```

A project's OpenBao side (its policies and empty secret paths) lives in
[kthaisociety/infrastructure](https://github.com/kthaisociety/infrastructure)'s `terraform/openbao`:
policies decide what a token can read, so this repo's CI can't write them. It only mints tokens.

## Adding a project

1. `infrastructure`: one line in `terraform/openbao/projects.yaml`, `my-app: {}` (staging and
   production; add `shared: [...]` if it reads shared secrets). That creates its policies and empty
   secret paths. This repo's `check` fails, with that line, until it's there.
2. Write its secrets in OpenBao (`secret/<project>/<environment>`).
3. Here: `projects/<project>/project.yaml`, and `release.yaml` with a line per environment, `null` until
   it has an image. Merging creates the Dokploy project, environments, vault providers, and each
   environment's app and volumes, not deployed. Setting an environment's image deploys it (its volumes
   are already attached). `release.yaml` is required, with every environment. `null` means "not
   deployed yet" only: once an environment has had an image, `check` rejects setting it back to `null`
   (roll back by setting a previous image).

## Rules

- Everything changes by PR, squash-merged, with a Conventional Commit title.
- Humans' PRs need a code owner's approval. The deployments bot's PRs skip that approval, never the
  checks, and may only change `projects/*/release.yaml` (`bot-scope`).
- Public by design: no secret value is ever in this repo. Values live in OpenBao.

## Deploying

- **Automatically**, from an app repo that has opted in (a `request-deploy` job in its `build.yml` for
  staging, in its `release.yml` for production): its CI starts `deploy.yml` here with the project,
  environment and tag, and waits for the result.
- **By hand**: Actions → deploy → Run workflow, with the project, environment, tag (`sha-<7>` or
  `X.Y.Z`) and any request id. Or a PR changing the `release.yaml` line yourself.

`deploy.yml` looks up the tag's digest in GHCR itself, and for production requires a GitHub Release whose
commit was built as exactly that digest. It changes the one line through a PR by `kthais-deploy`, which
must pass the same required checks as any PR (plus `bot-scope`: exactly one `release.yaml`) and only
skips human review. It reports success only once a `tofu` run on `main` has actually applied a commit
containing the line (starting one if needed). Requests can run concurrently: each is its own PR, and
applies run one at a time.
