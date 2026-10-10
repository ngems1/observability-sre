# OpsDesk AWS infrastructure: one module per component (terraform/modules/<component>).
#
#   shared platform (one each)          per environment (dev, prod) -> modules/environment
#   ------------------------------      ---------------------------------------------------
#   kms        encryption key           sqs      queue + DLQ
#   network    VPC, subnets, NAT        rds      PostgreSQL instance, own credentials
#   eks        cluster + node group     secrets  app secret (API keys, webhook token)
#   ecr        image repository         IAM      roles for its pods, trusted only in its namespace
#   observability  SNS + budget         ops      log group, Logs Insights queries, CloudWatch alarms
#   irsa       controller roles
#   security   GuardDuty & co.
#
# The in-cluster platform (namespaces, quotas, controllers, monitoring) is the separate root terraform/platform.

module "kms" {
  source = "../modules/kms"

  name = local.name
}

module "network" {
  source = "../modules/network"

  name                       = local.name
  region                     = var.region
  vpc_cidr                   = var.vpc_cidr
  azs                        = local.azs
  enable_interface_endpoints = var.enable_interface_endpoints
  log_retention_days         = var.log_retention_days
}

module "eks" {
  source = "../modules/eks"

  cluster_name         = local.name
  cluster_version      = var.eks_version
  vpc_id               = module.network.vpc_id
  subnet_ids           = module.network.private_subnets
  public_access_cidrs  = var.eks_public_access_cidrs
  admin_principal_arns = var.admin_principal_arns
  log_retention_days   = var.log_retention_days

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_ami_type       = var.node_ami_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

module "ecr" {
  source = "../modules/ecr"

  repository_name = var.project
  kms_key_arn     = module.kms.key_arn
}

module "observability" {
  source = "../modules/observability"

  name               = local.name
  project            = var.project
  kms_key_arn        = module.kms.key_arn
  alert_email        = var.alert_email
  monthly_budget_usd = var.monthly_budget_usd
}

module "env" {
  source   = "../modules/environment"
  for_each = local.environments

  environment = each.key
  name        = each.value
  namespace   = each.value
  app_release = var.app_release

  kms_key_arn            = module.kms.key_arn
  vpc_id                 = module.network.vpc_id
  db_subnet_group_name   = module.network.database_subnet_group_name
  node_security_group_id = module.eks.node_security_group_id
  oidc_provider_arn      = module.eks.oidc_provider_arn
  oidc_issuer_url        = module.eks.cluster_oidc_issuer_url
  sns_topic_arn          = module.observability.sns_topic_arn

  db_instance_class       = var.db_instance_class
  db_allocated_storage_gb = var.db_allocated_storage_gb
  db_multi_az             = var.db_multi_az
  db_performance_insights = var.db_performance_insights
  log_retention_days      = var.log_retention_days
  slack_webhook_url       = var.slack_webhook_url
}

module "irsa" {
  source = "../modules/irsa"

  name               = local.name
  cluster_name       = module.eks.cluster_name
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_issuer_url    = module.eks.cluster_oidc_issuer_url
  domain_name        = var.domain_name
  app_log_group_arns = [for e in module.env : e.log_group_arn]
}

module "security" {
  source = "../modules/security"

  name               = local.name
  enable_guardduty   = var.enable_guardduty
  enable_securityhub = var.enable_securityhub
  enable_inspector   = var.enable_inspector
  enable_cloudtrail  = var.enable_cloudtrail
}
