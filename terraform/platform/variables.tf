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

variable "namespace_quotas" {
  description = "ResourceQuota per environment namespace: dev can never take prod's capacity (noisy-neighbour drill)."
  type = map(object({
    requests_cpu    = string
    requests_memory = string
    limits_memory   = string
    pods            = number
  }))
  default = {
    dev  = { requests_cpu = "2", requests_memory = "3Gi", limits_memory = "6Gi", pods = 20 }
    prod = { requests_cpu = "3", requests_memory = "4Gi", limits_memory = "8Gi", pods = 30 }
  }
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
