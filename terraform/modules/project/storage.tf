# Object storage. kthaisociety/infrastructure gives a project with `storage` in its
# terraform/openbao/projects.yaml, per environment, its own GleSYS instance and buckets, and writes what
# the app needs to reach them to secret/<project>/<env>/storage. Nothing to create here: an app reads a setting
# by listing its name in secrets, and these names always read that path (main.tf, env_lines). Without
# storage in infrastructure, the path doesn't exist and the deploy fails resolving the reference.

locals {
  storage_keys = ["S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "S3_ENDPOINT", "S3_REGION", "S3_BUCKET"]
  # And one per bucket of a `buckets` list: `user-files` is S3_BUCKET_USER_FILES (no S3_BUCKET then).
  storage_bucket_pattern = "^S3_BUCKET_[A-Z0-9]+(_[A-Z0-9]+)*$"

  # Per environment, name => the secret it reads, like database_secret (databases.tf).
  storage_secret = {
    for e, c in local.environments : e => {
      for k in c.secrets : k => "${local.secret_path[e]}/storage"
      if contains(local.storage_keys, k) || can(regex(local.storage_bucket_pattern, k))
    }
  }
}
