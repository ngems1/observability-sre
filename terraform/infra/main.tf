# OpsDesk AWS infrastructure: one module per component (terraform/modules/<component>).
# Read top to bottom in dependency order:
#   kms -> network -> eks -> ecr / sqs / secrets -> rds -> observability -> irsa -> security
# The in-cluster platform (load balancer controller, monitoring, External Secrets) is a separate root:
# terraform/platform, which reads this root's outputs from remote state.

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

module "sqs" {
  source = "../modules/sqs"

  name_prefix = var.project
  kms_key_arn = module.kms.key_arn
}

module "secrets" {
  source = "../modules/secrets"

  name              = local.name
  kms_key_arn       = module.kms.key_arn
  slack_webhook_url = var.slack_webhook_url
}

module "rds" {
  source = "../modules/rds"

  name                      = local.name
  vpc_id                    = module.network.vpc_id
  db_subnet_group_name      = module.network.database_subnet_group_name
  allowed_security_group_id = module.eks.node_security_group_id
  kms_key_arn               = module.kms.key_arn
  instance_class            = var.db_instance_class
  allocated_storage_gb      = var.db_allocated_storage_gb
  multi_az                  = var.db_multi_az
  performance_insights      = var.db_performance_insights
  log_retention_days        = var.log_retention_days
}

module "observability" {
  source = "../modules/observability"

  name               = local.name
  project            = var.project
  environment        = var.environment
  kms_key_arn        = module.kms.key_arn
  log_retention_days = var.log_retention_days
  alert_email        = var.alert_email
  monthly_budget_usd = var.monthly_budget_usd
  queue_name         = module.sqs.queue_name
  dlq_name           = module.sqs.dlq_name
  db_identifier      = module.rds.identifier
}

module "irsa" {
  source = "../modules/irsa"

  name                 = local.name
  cluster_name         = module.eks.cluster_name
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_issuer_url      = module.eks.cluster_oidc_issuer_url
  app_namespace        = var.app_namespace
  app_release          = var.app_release
  queue_arn            = module.sqs.queue_arn
  dlq_arn              = module.sqs.dlq_arn
  kms_key_arn          = module.kms.key_arn
  readable_secret_arns = [module.secrets.secret_arn, module.rds.master_user_secret_arn]
  app_log_group_arn    = module.observability.app_log_group_arn
}

module "security" {
  source = "../modules/security"

  name               = local.name
  enable_guardduty   = var.enable_guardduty
  enable_securityhub = var.enable_securityhub
  enable_inspector   = var.enable_inspector
  enable_cloudtrail  = var.enable_cloudtrail
}
