output "state_bucket" {
  description = "Terraform state bucket (the workflows derive the same name automatically)."
  value       = aws_s3_bucket.state.bucket
}

output "deploy_role_arn" {
  description = "GitHub repository variable AWS_ROLE_ARN."
  value       = module.github_oidc.role_arn
}

output "next_steps" {
  description = "What to do after the bootstrap."
  value       = "GitHub -> Settings -> Secrets and variables -> Actions -> Variables: AWS_ROLE_ARN = ${module.github_oidc.role_arn}"
}
