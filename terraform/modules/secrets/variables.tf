variable "name" {
  description = "Name prefix; the secret is <name>/app."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK that encrypts the secret."
  type        = string
}

variable "demo_users" {
  description = "Demo logins to generate API keys for: name => role (requester, approver, admin)."
  type        = map(string)
  default = {
    alice = "requester"
    bob   = "approver"
    dave  = "approver"
    carol = "admin"
  }
}

variable "slack_webhook_url" {
  description = "Optional Slack incoming webhook; empty = worker logs notifications only."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Extra tags (e.g. Env = dev) on top of the provider default tags."
  type        = map(string)
  default     = {}
}
