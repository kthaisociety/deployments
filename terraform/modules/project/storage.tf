# Object storage. kthaisociety/infrastructure gives a project with `storage: true` in its
# terraform/openbao/projects.yaml, per environment, its own GleSYS instance and bucket, and writes what the
# app needs to reach it to secret/<project>/<env>/storage. Nothing to create here: an app reads a setting
# by listing its name in secrets, and these names always read that path (main.tf, env_lines). Without
# storage in infrastructure, the path doesn't exist and the deploy fails resolving the reference.

locals {
  storage_keys = ["S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "S3_ENDPOINT", "S3_REGION", "S3_BUCKET"]

  # Per environment, name => the secret it reads, like database_secret (databases.tf).
  storage_secret = {
    for e, _ in local.environments : e => { for k in local.storage_keys : k => "${local.secret_path[e]}/storage" }
  }
}
