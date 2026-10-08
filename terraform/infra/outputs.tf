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

output "app_log_group" {
  value = module.observability.app_log_group_name
}

# Everything the Helm chart needs on EKS. scripts/aws/deploy-app.sh writes this to
# helm/opsdesk/values-eks.generated.yaml (git-ignored) and layers it on values-eks.yaml.
output "helm_values" {
  value = yamlencode({
    image = {
      repository = module.ecr.repository_url
    }
    config = {
      OPSDESK_AWS_REGION     = var.region
      OPSDESK_SQS_QUEUE_NAME = module.sqs.queue_name
    }
    serviceAccount = {
      api    = { annotations = { "eks.amazonaws.com/role-arn" = module.irsa.role_arns.ticket_api } }
      worker = { annotations = { "eks.amazonaws.com/role-arn" = module.irsa.role_arns.ticket_worker } }
    }
    externalSecrets = {
      enabled       = true
      region        = var.region
      appSecretName = module.secrets.secret_name
      dbSecretArn   = module.rds.master_user_secret_arn
      dbHost        = module.rds.address
      dbName        = module.rds.db_name
    }
  })
}

# Demo login keys (also in Secrets Manager). `terraform output -json demo_api_keys`
output "demo_api_keys" {
  value     = module.secrets.demo_api_keys
  sensitive = true
}

# Read by the platform root (remote state) to give Alertmanager the same bearer token as the API
output "alert_webhook_token" {
  value     = module.secrets.alert_webhook_token
  sensitive = true
}

output "sns_alerts_topic_arn" {
  value = module.observability.sns_topic_arn
}
