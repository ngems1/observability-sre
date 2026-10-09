variable "name" {
  description = "Name prefix for the roles."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (scopes the Cluster Autoscaler policy)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider of the cluster."
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster (https://oidc.eks...)."
  type        = string
}

variable "app_log_group_arns" {
  description = "Log groups Fluent Bit may write to (one per environment)."
  type        = list(string)
}
