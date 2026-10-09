output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "next_steps" {
  value = <<-EOT
    Platform ready. Next:
      APP_ENV=dev scripts/aws/deploy-app.sh   # build -> push to ECR -> helm upgrade --install -> smoke test
      kubectl get ingress -A               # ALB hostname (takes ~2-3 min to provision)
      terraform -chdir=terraform/platform output -raw grafana_admin_password
  EOT
}

# Per environment, merged on top of the infra helm_values by scripts/aws/deploy-app.sh.
# Each environment gets its own ALB (ingress group opsdesk-<env>); both route /grafana to the shared Grafana.
output "helm_values" {
  value = {
    for env, e in local.environments : env => yamlencode({
      config = {
        OPSDESK_OTEL_EXPORTER_OTLP_ENDPOINT = "http://otel-collector.${kubernetes_namespace_v1.observability.metadata[0].name}.svc.cluster.local:4318"
        OPSDESK_GRAFANA_URL                 = "/grafana" # the shared Grafana, routed on each environment's ALB
      }
      ingress = {
        annotations = merge(local.alb_common_annotations, {
          "alb.ingress.kubernetes.io/group.name"       = "opsdesk-${env}"
          "alb.ingress.kubernetes.io/group.order"      = "20"
          "alb.ingress.kubernetes.io/healthcheck-path" = "/readyz"
        })
      }
    })
  }
}
