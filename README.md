# deployments

What every KTHAIS project runs: its Dokploy project, its OpenBao secrets wiring, and the exact image of
each environment. Merging here is deploying.

The design is in
[kthaisociety/infrastructure: docs/delivery-plan.md](https://github.com/kthaisociety/infrastructure/blob/main/docs/delivery-plan.md),
the step-by-step guide in
[docs/app-delivery.md](https://github.com/kthaisociety/infrastructure/blob/main/docs/app-delivery.md).
`infrastructure` holds the platform underneath (OpenBao, Dokploy core, storage); this repo holds the
projects on top of it.

## Layout (being built)

```
projects/<project>/
  project.yaml    # config, secret names, environments (staging, production)
  release.yaml    # the image each environment runs, tag@digest; written by the deploy bot
modules/          # project (Dokploy side), project-secrets (OpenBao side)
.github/workflows/
  pr.yml          # PR checks
  deploy.yml      # deploy requests from app repos: check, bot PR on release.yaml, apply
```

## Rules

- Everything changes by PR, squash-merged, with a Conventional Commit title.
- Humans' PRs need a code owner's approval. The deployments bot's PRs skip that approval, never the
  checks, and may only change `projects/*/release.yaml` (`bot-scope`).
- Public by design: no secret value is ever in this repo. Values live in OpenBao.
