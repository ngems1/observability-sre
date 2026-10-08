variable "name_prefix" {
  description = "Queue name prefix: <prefix>-notifications and <prefix>-notifications-dlq (the app expects 'opsdesk')."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK used for SQS server-side encryption."
  type        = string
}

variable "max_receive_count" {
  description = "Receives before a message moves to the DLQ."
  type        = number
  default     = 3
}
