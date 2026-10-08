variable "repository_name" {
  description = "ECR repository name (the workflows look it up as 'opsdesk')."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK used to encrypt images at rest."
  type        = string
}
