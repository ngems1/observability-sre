output "repository_url" {
  description = "Image repository URL (<account>.dkr.ecr.<region>.amazonaws.com/<name>)."
  value       = aws_ecr_repository.app.repository_url
}

output "repository_name" {
  description = "Repository name."
  value       = aws_ecr_repository.app.name
}
