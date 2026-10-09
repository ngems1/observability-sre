variable "environment" {
  description = "Environment name (dev, prod): tag Env and alarm descriptions."
  type        = string
}

variable "name" {
  description = "Resource name prefix for this environment, e.g. opsdesk-dev (queues, DB, secret, roles, alarms)."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of this environment; IAM roles trust only service accounts in it."
  type        = string
}

variable "app_release" {
  description = "Helm release name in the namespace; service accounts are <release>-api, -worker, -secrets."
  type        = string
}

variable "kms_key_arn" {
  description = "Shared application CMK."
  type        = string
}

variable "vpc_id" {
  description = "Shared VPC."
  type        = string
}

variable "db_subnet_group_name" {
  description = "Shared DB subnet group (database subnets)."
  type        = string
}

variable "node_security_group_id" {
  description = "EKS node security group allowed to reach this environment's database."
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS cluster OIDC provider (IRSA)."
  type        = string
}

variable "oidc_issuer_url" {
  description = "EKS cluster OIDC issuer URL."
  type        = string
}

variable "sns_topic_arn" {
  description = "Shared alarm topic (email)."
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "db_allocated_storage_gb" {
  description = "RDS storage."
  type        = number
}

variable "db_multi_az" {
  description = "RDS Multi-AZ standby."
  type        = bool
}

variable "db_performance_insights" {
  description = "RDS Performance Insights."
  type        = bool
}

variable "log_retention_days" {
  description = "Retention of this environment's log groups."
  type        = number
}

variable "slack_webhook_url" {
  description = "Optional Slack webhook for this environment's notifications."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Extra tags; Env = <environment> is added."
  type        = map(string)
  default     = {}
}
