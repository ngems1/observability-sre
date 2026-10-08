output "queue_arn" {
  description = "Notification queue ARN."
  value       = aws_sqs_queue.notifications.arn
}

output "queue_name" {
  description = "Notification queue name."
  value       = aws_sqs_queue.notifications.name
}

output "dlq_arn" {
  description = "Dead-letter queue ARN."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Dead-letter queue name."
  value       = aws_sqs_queue.dlq.name
}
