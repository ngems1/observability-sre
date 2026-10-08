variable "name" {
  description = "Name prefix (project-environment)."
  type        = string
}

variable "project" {
  description = "Project name (log group path and the budget's Project tag filter)."
  type        = string
}

variable "environment" {
  description = "Environment name (log group path)."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK for the log group and the SNS topic."
  type        = string
}

variable "log_retention_days" {
  description = "Retention of the app log group."
  type        = number
}

variable "alert_email" {
  description = "Receives the CloudWatch alarms and budget alerts (confirm the SNS subscription once)."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly budget for resources tagged Project=<project>."
  type        = number
}

variable "queue_name" {
  description = "Notification queue (queue-age alarm)."
  type        = string
}

variable "dlq_name" {
  description = "Dead-letter queue (DLQ-not-empty alarm)."
  type        = string
}

variable "db_identifier" {
  description = "RDS instance identifier (CPU and storage alarms)."
  type        = string
}
