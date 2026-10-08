# App secret in Secrets Manager (KMS-encrypted). External Secrets Operator syncs it into the cluster;
# nothing secret lives in Git or in Helm values.
#   - bootstrap_users: name:role:api_key list used by the migrate step (keys generated here)
#   - slack_webhook_url: optional
#   - alert_webhook_token: bearer token Alertmanager uses to open incident tickets (/integrations/alertmanager)
# The DB credentials are NOT here: RDS manages them in its own secret.

resource "random_password" "api_key" {
  for_each = var.demo_users
  length   = 32
  special  = false
}

# Shared by the API (via External Secrets) and Alertmanager (platform root, Kubernetes Secret)
resource "random_password" "alert_webhook_token" {
  length  = 40
  special = false
}

locals {
  bootstrap_users = join(",", [for name, role in var.demo_users : "${name}:${role}:${random_password.api_key[name].result}"])
}

resource "aws_secretsmanager_secret" "app" {
  #checkov:skip=CKV2_AWS_57:Demo API keys rotate with `terraform apply -replace`; DB credentials are rotated by RDS
  name                    = "${var.name}/app"
  description             = "OpsDesk app secrets (bootstrap API keys, Slack webhook, Alertmanager webhook token)"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 0 # demo: allow immediate re-create after destroy
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    bootstrap_users     = local.bootstrap_users
    slack_webhook_url   = var.slack_webhook_url
    alert_webhook_token = random_password.alert_webhook_token.result
  })
}
