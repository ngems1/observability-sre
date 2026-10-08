output "key_arn" {
  description = "ARN of the application CMK."
  value       = aws_kms_key.app.arn
}

output "key_id" {
  description = "Key ID of the application CMK."
  value       = aws_kms_key.app.key_id
}
