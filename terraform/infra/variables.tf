variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "opsdesk"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "owner" {
  description = "Owner tag (your name or email). Used for cost allocation."
  type        = string
}

variable "alert_email" {
  description = "Receives budget alerts and the out-of-cluster CloudWatch alarms (confirm the SNS email once)."
  type        = string
}

variable "monthly_budget_usd" {
  description = "AWS Budget for everything tagged Project=opsdesk."
  type        = number
  default     = 150
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "enable_interface_endpoints" {
  description = "ECR/SQS/Secrets Manager/Logs/STS interface endpoints. Off by default: they cost more than the NAT traffic they save at demo scale."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- EKS
variable "eks_version" {
  description = "Pick a version in STANDARD support (extended support costs extra per cluster-hour). Check the EKS console or docs."
  type        = string
  default     = "1.35"
}

variable "eks_public_access_cidrs" {
  description = "Who may reach the EKS API endpoint. CloudShell egress IPs vary, so the default is open; narrow it if you can (documented finding)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Cost baseline = m5.large x3. Optimization step (Day 4) = m6g.large x2 with ami_type AL2023_ARM_64_STANDARD and multi-arch images."
  type        = list(string)
  default     = ["m5.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND (baseline) or SPOT (cost recommendation 2 in docs/cost.md; list several instance types for Spot)."
  type        = string
  default     = "ON_DEMAND"
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_ami_type" {
  type    = string
  default = "AL2023_x86_64_STANDARD"
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "admin_principal_arns" {
  description = "Extra IAM users/roles that get cluster-admin through EKS access entries (the identity running Terraform always gets it)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------- RDS
variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 20
}

variable "db_multi_az" {
  description = "Single-AZ for the demo (documented trade-off); true for production."
  type        = bool
  default     = false
}

variable "db_performance_insights" {
  type    = bool
  default = false
}

# ---------------------------------------------------------------- app
variable "app_namespace" {
  type    = string
  default = "opsdesk"
}

variable "app_release" {
  description = "Helm release name; service account names derive from it (<release>-api, <release>-worker)."
  type        = string
  default     = "opsdesk"
}

variable "slack_webhook_url" {
  description = "Optional. Empty = worker runs in log-only mode."
  type        = string
  default     = ""
  sensitive   = true
}

variable "log_retention_days" {
  type    = number
  default = 7
}

# ---------------------------------------------------------------- Day 4 security services
variable "enable_guardduty" {
  description = "Turn on for Day 4 (30-day free trial, then paid). Turn off in the teardown checklist."
  type        = bool
  default     = false
}

variable "enable_securityhub" {
  type    = bool
  default = false
}

variable "enable_inspector" {
  type    = bool
  default = false
}

variable "enable_cloudtrail" {
  type    = bool
  default = false
}
