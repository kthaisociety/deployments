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
  deploy.yml      # deploy requests: validate, commit the release.yaml line, apply, report (one run)
```

A project's OpenBao side (its policies and empty secret paths) lives in
[kthaisociety/infrastructure](https://github.com/kthaisociety/infrastructure)'s `terraform/openbao`:
policies decide what a token can read, so this repo's CI can't write them. It only mints tokens.

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
