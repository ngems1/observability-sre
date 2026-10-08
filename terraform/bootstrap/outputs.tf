output "state_bucket" {
  description = "Terraform state bucket (the workflows derive the same name automatically)."
  value       = aws_s3_bucket.state.bucket
}

output "deploy_role_arn" {
  description = "GitHub repository variable AWS_ROLE_ARN (null when the role was created in the IAM console)."
  value       = try(module.github_oidc[0].role_arn, null)
}
