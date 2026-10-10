output "role_arns" {
  description = "IRSA role ARNs of the platform controllers (consumed by the platform root)."
  value = {
    lb_controller      = module.irsa_lb_controller.iam_role_arn
    cluster_autoscaler = module.irsa_cluster_autoscaler.iam_role_arn
    fluent_bit         = aws_iam_role.fluent_bit.arn
    external_dns       = try(module.irsa_external_dns[0].iam_role_arn, null)
  }
}
