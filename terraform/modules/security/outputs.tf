output "enabled_services" {
  description = "Which detective controls are on."
  value = {
    guardduty   = var.enable_guardduty
    securityhub = var.enable_securityhub
    inspector   = var.enable_inspector
    cloudtrail  = var.enable_cloudtrail
  }
}
