output "identifier" {
  description = "RDS instance identifier (CloudWatch alarm dimension)."
  value       = aws_db_instance.main.identifier
}

output "address" {
  description = "Database host name."
  value       = aws_db_instance.main.address
}

output "db_name" {
  description = "Database name."
  value       = aws_db_instance.main.db_name
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the RDS-managed master credentials."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
