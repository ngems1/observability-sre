output "namespace" {
  description = "Kubernetes namespace of this environment."
  value       = var.namespace
}

output "queue_name" {
  description = "Notification queue name."
  value       = module.sqs.queue_name
}

output "role_arns" {
  description = "IRSA roles of this environment's service accounts."
  value       = { for k, r in aws_iam_role.app : k => r.arn }
}

output "app_secret_name" {
  description = "Secrets Manager name of the app secret."
  value       = module.secrets.secret_name
}

output "db_secret_arn" {
  description = "RDS-managed master secret."
  value       = module.rds.master_user_secret_arn
}

output "db_host" {
  description = "Database host."
  value       = module.rds.address
}

output "db_name" {
  description = "Database name."
  value       = module.rds.db_name
}

output "log_group_name" {
  description = "CloudWatch log group of this environment."
  value       = aws_cloudwatch_log_group.app.name
}

output "log_group_arn" {
  description = "ARN of the log group (Fluent Bit permission)."
  value       = aws_cloudwatch_log_group.app.arn
}

output "demo_api_keys" {
  description = "Generated demo logins for this environment."
  value       = module.secrets.demo_api_keys
  sensitive   = true
}

output "alert_webhook_token" {
  description = "Bearer token Alertmanager uses for this environment's OpsDesk."
  value       = module.secrets.alert_webhook_token
  sensitive   = true
}
