variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "S3 bucket from terraform/bootstrap (same one the infra root uses)."
  type        = string
}

variable "allowed_cidrs" {
  description = "Who may reach the ALB (app + Grafana). Your public IP as x.x.x.x/32 keeps it private; 0.0.0.0/0 opens the demo to anyone with the URL, leaving the app login as the only control."
  type        = list(string)
}

variable "domain_name" {
  description = "Optional. Apex of the Route 53 hosted zone (same value as the bootstrap root), e.g. example.click. Set: HTTPS on dev.<domain> and opsdesk.<domain>, with HTTP redirected. Empty: HTTP on the raw load-balancer hostname."
  type        = string
  default     = ""
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
