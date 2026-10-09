output "sns_topic_arn" {
  description = "SNS topic of the out-of-cluster alarms (all environments)."
  value       = aws_sns_topic.alerts.arn
}
