output "state_bucket" {
  description = "Terraform state bucket (the workflows derive the same name automatically)."
  value       = aws_s3_bucket.state.bucket
}

output "deploy_role_arn" {
  description = "GitHub repository variable AWS_ROLE_ARN (null when the role was created in the IAM console)."
  value       = try(module.github_oidc[0].role_arn, null)
}

output "certificate_arn" {
  description = "ACM certificate for the custom domain (null when domain_name is empty). The platform root finds it by domain, so this is informational."
  value       = try(aws_acm_certificate_validation.this[0].certificate_arn, null)
}

output "domain_name" {
  description = "Custom domain in use, if any."
  value       = var.domain_name
}
