# Output names are a contract: terraform/platform (remote state), scripts/aws/*.sh and the workflows read them.

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  value = module.network.vpc_id
}

# The ALB lives in the public subnets: the app's NetworkPolicy admits load-balancer traffic from these ranges only
output "public_subnet_cidrs" {
  value = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

# Consumed by terraform/platform (remote state)
output "irsa_role_arns" {
  value = module.irsa.role_arns
}

output "kms_key_arn" {
  value = module.kms.key_arn
}

output "environments" {
  description = "Per-environment facts for the platform root: namespace and log group."
  value       = { for k, e in module.env : k => { namespace = e.namespace, log_group = e.log_group_name } }
}

# Everything the Helm chart needs, per environment. scripts/aws/deploy-app.sh picks .<env> and writes it to
# helm/opsdesk/values-eks.generated.yaml (git-ignored), layered on values-eks.yaml + values-<env>.yaml.
output "helm_values" {
  value = {
    for k, e in module.env : k => yamlencode({
      image = {
        repository = module.ecr.repository_url
      }
      config = {
        OPSDESK_AWS_REGION     = var.region
        OPSDESK_SQS_QUEUE_NAME = e.queue_name
      }
      serviceAccount = {
        api     = { annotations = { "eks.amazonaws.com/role-arn" = e.role_arns["api"] } }
        worker  = { annotations = { "eks.amazonaws.com/role-arn" = e.role_arns["worker"] } }
        secrets = { annotations = { "eks.amazonaws.com/role-arn" = e.role_arns["secrets"] } }
      }
      externalSecrets = {
        enabled       = true
        region        = var.region
        appSecretName = e.app_secret_name
        dbSecretArn   = e.db_secret_arn
        dbHost        = e.db_host
        dbName        = e.db_name
      }
      networkPolicy = {
        loadBalancerCidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
      }
    })
  }
}

# Demo login keys per environment (also in Secrets Manager <project>-<env>/app)
output "demo_api_keys" {
  value     = { for k, e in module.env : k => e.demo_api_keys }
  sensitive = true
}

# Read by the platform root (remote state): Alertmanager uses each environment's own bearer token
output "alert_webhook_tokens" {
  value     = { for k, e in module.env : k => e.alert_webhook_token }
  sensitive = true
}

output "sns_alerts_topic_arn" {
  value = module.observability.sns_topic_arn
}
