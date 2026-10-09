variable "github_repository" {
  description = "GitHub repository allowed to assume the role, as owner/name (e.g. ngems1/observability-sre). Case-sensitive."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Use the form owner/repository, e.g. ngems1/observability-sre."
  }
}

variable "subject_repository" {
  description = "The repository as it appears in the token's sub claim, if GitHub sends immutable IDs (e.g. ngems1@330211773/observability-sre@1410480281). null = github_repository."
  type        = string
  default     = null
}

variable "role_name" {
  description = "Name of the IAM role GitHub Actions assumes (goes into the AWS_ROLE_ARN repository variable)."
  type        = string
}

variable "allowed_subjects" {
  description = "OIDC subject suffixes allowed to assume the role (branch, pull requests, environment)."
  type        = list(string)
  default     = ["ref:refs/heads/main", "pull_request", "environment:dev", "environment:prod"]
}

variable "create_oidc_provider" {
  description = "false if IAM -> Identity providers already lists token.actions.githubusercontent.com (one per account)."
  type        = bool
  default     = true
}
