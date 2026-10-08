output "role_arns" {
  description = "IRSA role ARNs, keyed by workload (consumed by the platform root and the Helm values)."
  value = {
    ticket_api         = aws_iam_role.api.arn
    ticket_worker      = aws_iam_role.worker.arn
    lb_controller      = module.irsa_lb_controller.iam_role_arn
    cluster_autoscaler = module.irsa_cluster_autoscaler.iam_role_arn
    external_secrets   = aws_iam_role.external_secrets.arn
    fluent_bit         = aws_iam_role.fluent_bit.arn
  }
}
