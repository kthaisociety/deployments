output "project_id" {
  value = dokploy_project.this.id
}

output "apps" {
  description = "Per deployed environment: the app's internal name (its host name on dokploy-network), image and volumes."
  value = {
    for e, a in dokploy_application.this : e => {
      app_name = a.app_name
      image    = local.deployed[e].image
      volumes  = [for k, v in local.volumes : v.volume if v.env == e]
    }
  }
}
