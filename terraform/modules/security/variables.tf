variable "name" {
  description = "Name prefix (CloudTrail trail and bucket)."
  type        = string
}

variable "enable_guardduty" {
  description = "GuardDuty with EKS audit-log and runtime monitoring (30-day trial, then paid)."
  type        = bool
  default     = false
}

variable "enable_securityhub" {
  description = "Security Hub with the AWS Foundational Security Best Practices standard."
  type        = bool
  default     = false
}

variable "enable_inspector" {
  description = "Inspector CVE scanning of ECR images and EC2 nodes."
  type        = bool
  default     = false
}

variable "enable_cloudtrail" {
  description = "Multi-region CloudTrail (management events) to an S3 bucket."
  type        = bool
  default     = false
}
