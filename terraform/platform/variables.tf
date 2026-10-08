variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "S3 bucket from terraform/bootstrap (same one the infra root uses)."
  type        = string
}

variable "allowed_cidrs" {
  description = "Who may reach the ALB (app + Grafana). Use your public IP as x.x.x.x/32. The app is an internal tool: do not open it to 0.0.0.0/0."
  type        = list(string)
}

variable "app_namespace" {
  type    = string
  default = "opsdesk"
}

variable "prometheus_retention" {
  type    = string
  default = "3d"
}

variable "chart_versions" {
  description = "Optional pins, e.g. { kube_prometheus_stack = \"77.0.0\" }. Empty = latest at install time; pin after the first install (`helm list -A`)."
  type        = map(string)
  default     = {}
}
