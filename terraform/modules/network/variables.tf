variable "name" {
  description = "Name prefix for every resource (project-environment)."
  type        = string
}

variable "region" {
  description = "AWS region (used in VPC endpoint service names)."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block; subnets are carved from it."
  type        = string
}

variable "azs" {
  description = "Availability zones to spread the subnets across."
  type        = list(string)
}

variable "enable_interface_endpoints" {
  description = "Create ECR/SQS/Secrets Manager/Logs/STS interface endpoints."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention of the VPC flow log group."
  type        = number
}
