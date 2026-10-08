output "role_arn" {
  description = "Put this in the GitHub repository variable AWS_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider for token.actions.githubusercontent.com."
  value       = local.oidc_provider_arn
}
