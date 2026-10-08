output "app_log_group_name" {
  description = "CloudWatch log group of the app (Fluent Bit target)."
  value       = aws_cloudwatch_log_group.app.name
}

output "app_log_group_arn" {
  description = "ARN of the app log group."
  value       = aws_cloudwatch_log_group.app.arn
}

output "sns_topic_arn" {
  description = "SNS topic of the out-of-cluster alarms."
  value       = aws_sns_topic.alerts.arn
}
