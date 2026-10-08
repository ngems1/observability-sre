variable "region" {
  description = "Region of the state bucket (the workflows expect us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefix of the state bucket (<project>-tfstate-<account>-<region>) and the deploy role (<project>-github-deploy)."
  type        = string
  default     = "opsdesk"
}

variable "github_repository" {
  description = "GitHub repository whose workflows may deploy, as owner/name (case-sensitive)."
  type        = string
  default     = "ngems1/observability-sre"
}

variable "create_oidc_provider" {
  description = "false if IAM -> Identity providers already lists token.actions.githubusercontent.com (e.g. from an earlier project)."
  type        = bool
  default     = true
}

variable "manage_github_oidc" {
  description = "true = also create the GitHub OIDC provider and deploy role (CloudShell path); false = they were created in the IAM console."
  type        = bool
  default     = true
}
