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
  deploy.yml      # deploy requests from app repos: check, bot PR on release.yaml, apply [to do]
```

A project's OpenBao side (its policies and empty secret paths) lives in
[kthaisociety/infrastructure](https://github.com/kthaisociety/infrastructure)'s `terraform/openbao`:
policies decide what a token can read, so this repo's CI can't write them. It only mints tokens.

## Adding a project

1. `infrastructure`: one line in `terraform/openbao/projects.yaml`, `my-app: {}` (staging and
   production; add `shared: [...]` if it reads shared secrets). That creates its policies and empty
   secret paths. This repo's `check` fails, with that line, until it's there.
2. Write its secrets in OpenBao (`secret/<project>/<environment>`).
3. Here: `projects/<project>/project.yaml`, and `release.yaml` with `null` per environment. Merging
   creates the Dokploy project, environments and vault providers; an app appears once its environment
   has an image.

## Rules

- Everything changes by PR, squash-merged, with a Conventional Commit title.
- Humans' PRs need a code owner's approval. The deployments bot's PRs skip that approval, never the
  checks, and may only change `projects/*/release.yaml` (`bot-scope`).
- Public by design: no secret value is ever in this repo. Values live in OpenBao.
