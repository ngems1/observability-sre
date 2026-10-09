variable "name" {
  description = "Name prefix (project-environment); the instance is <name>-pg."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the database security group."
  type        = string
}

variable "db_subnet_group_name" {
  description = "DB subnet group (database subnets, no internet route)."
  type        = string
}

variable "allowed_security_group_id" {
  description = "Only this security group (the EKS nodes) may connect on 5432."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK for storage, the RDS-managed master secret and the log group."
  type        = string
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "opsdesk"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "allocated_storage_gb" {
  description = "Initial storage; autoscaling allows up to twice this."
  type        = number
}

variable "multi_az" {
  description = "Standby in a second AZ (production) or single-AZ (demo)."
  type        = bool
}

variable "performance_insights" {
  description = "Enable Performance Insights."
  type        = bool
}

variable "log_retention_days" {
  description = "Retention of the postgresql log group."
  type        = number
}

variable "tags" {
  description = "Extra tags (e.g. Env = dev) on top of the provider default tags."
  type        = map(string)
  default     = {}
}
