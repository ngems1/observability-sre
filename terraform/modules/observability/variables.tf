variable "name" {
  description = "Name prefix (topic and budget)."
  type        = string
}

variable "project" {
  description = "Project name (the budget's Project tag filter)."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK for the SNS topic."
  type        = string
}

variable "alert_email" {
  description = "Receives the CloudWatch alarms and budget alerts (confirm the SNS subscription once)."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly budget for resources tagged Project=<project>."
  type        = number
}
