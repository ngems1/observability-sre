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
