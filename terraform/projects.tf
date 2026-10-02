# Every folder under projects/ is a project: project.yaml says what it is, release.yaml which image each
# environment runs (written by the deploy bot). modules/project builds its Dokploy side.
#
# Its OpenBao side (the dokploy-project-<project>-<env> policies and empty secret paths) is in
# kthaisociety/infrastructure, which must list the project first: this repo can't write policies.

locals {
  projects = {
    for f in fileset(path.module, "../projects/*/project.yaml") :
    basename(dirname(f)) => {
      config = yamldecode(file("${path.module}/${f}"))
      # Required (check enforces it too): a missing release.yaml must fail, not read as "nothing deployed".
      release = yamldecode(file("${path.module}/../projects/${basename(dirname(f))}/release.yaml"))
    }
  }
}

module "project" {
  source   = "./modules/project"
  for_each = local.projects

  name    = each.key
  config  = each.value.config
  release = each.value.release
}

output "projects" {
  description = "Per project: its Dokploy project id, and per environment the app's internal name (its host name on dokploy-network), image and volumes."
  value = {
    for p, m in module.project : p => {
      project_id = m.project_id
      apps       = m.apps
    }
  }
}
