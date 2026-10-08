variable "name" {
  description = "Name prefix for the roles (project-environment)."
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

variable "app_namespace" {
  description = "Namespace of the OpsDesk Helm release."
  type        = string
}

variable "app_release" {
  description = "Helm release name; service accounts are <release>-api and <release>-worker."
  type        = string
}

variable "queue_arn" {
  description = "Notification queue the API publishes to and the worker consumes."
  type        = string
}

variable "dlq_arn" {
  description = "Dead-letter queue (the API reads its depth only)."
  type        = string
}

variable "kms_key_arn" {
  description = "Application CMK (SQS messages and secrets are encrypted with it)."
  type        = string
}

variable "readable_secret_arns" {
  description = "Secrets External Secrets Operator may read (app secret + RDS-managed DB secret)."
  type        = list(string)
}

variable "app_log_group_arn" {
  description = "CloudWatch log group Fluent Bit writes the app logs to."
  type        = string
}
