# IAM Roles for Service Accounts (IRSA) of the shared platform controllers.
# Application roles live in modules/environment (one set per environment, trusted only in its namespace).

locals {
  oidc_issuer = replace(var.oidc_issuer_url, "https://", "")
}

# ---------------------------------------------------------------- Fluent Bit -> CloudWatch Logs (app log groups only)
data "aws_iam_policy_document" "fluent_bit_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:logging:aws-for-fluent-bit"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "fluent_bit" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = flatten([for arn in var.app_log_group_arns : [arn, "${arn}:*"]])
  }
  statement {
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "fluent_bit" {
  name               = "${var.name}-fluent-bit"
  assume_role_policy = data.aws_iam_policy_document.fluent_bit_trust.json
}

resource "aws_iam_role_policy" "fluent_bit" {
  name   = "cloudwatch-app-logs"
  role   = aws_iam_role.fluent_bit.id
  policy = data.aws_iam_policy_document.fluent_bit.json
}

# ---------------------------------------------------------------- platform controllers
# The community IRSA module ships the official, maintained policies for these controllers.
module "irsa_lb_controller" {
  #checkov:skip=CKV_TF_1:Registry module pinned with a version constraint
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_name                              = "${var.name}-aws-lb-controller"
  attach_load_balancer_controller_policy = true
  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

module "irsa_cluster_autoscaler" {
  #checkov:skip=CKV_TF_1:Registry module pinned with a version constraint
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_name                        = "${var.name}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [var.cluster_name]
  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}

# ---------------------------------------------------------------- external-dns -> Route 53 (one hosted zone only)
# external-dns watches Ingresses and keeps the DNS records in step with whatever ALB the load balancer
# controller created. That matters here because the environment is torn down nightly: every rebuild gets a
# new ALB hostname, and without this the records would have to be repointed by hand each morning.
data "aws_route53_zone" "this" {
  count        = var.domain_name == "" ? 0 : 1
  name         = "${var.domain_name}."
  private_zone = false
}

module "irsa_external_dns" {
  #checkov:skip=CKV_TF_1:Registry module pinned with a version constraint
  count   = var.domain_name == "" ? 0 : 1
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_name                     = "${var.name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [data.aws_route53_zone.this[0].arn] # this zone, not "*"
  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }
}
