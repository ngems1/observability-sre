output "secret_arn" {
  description = "ARN of the app secret."
  value       = aws_secretsmanager_secret.app.arn
}

output "secret_name" {
  description = "Name of the app secret (External Secrets reads it by name)."
  value       = aws_secretsmanager_secret.app.name
}

output "demo_api_keys" {
  description = "Generated demo logins (also in the secret)."
  value       = { for name, role in var.demo_users : name => { role = role, api_key = random_password.api_key[name].result } }
  sensitive   = true
}

output "alert_webhook_token" {
  description = "Bearer token shared by the API and Alertmanager."
  value       = random_password.alert_webhook_token.result
  sensitive   = true
}
