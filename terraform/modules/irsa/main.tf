# IAM Roles for Service Accounts (IRSA): each pod gets only the AWS permissions it needs,
# with short-lived credentials from the cluster's OIDC provider. Nodes have no app permissions.

locals {
  oidc_issuer = replace(var.oidc_issuer_url, "https://", "")

  # Service accounts that may assume each hand-written role
  service_accounts = {
    api              = "system:serviceaccount:${var.app_namespace}:${var.app_release}-api"
    worker           = "system:serviceaccount:${var.app_namespace}:${var.app_release}-worker"
    external_secrets = "system:serviceaccount:external-secrets:external-secrets"
    fluent_bit       = "system:serviceaccount:logging:aws-for-fluent-bit"
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = local.service_accounts
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = [each.value]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------- ticket-api: publish only
data "aws_iam_policy_document" "api" {
  statement {
    sid       = "PublishNotifications"
    actions   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }
  statement {
    sid       = "ReadDlqDepth" # opsdesk_queue_messages{queue="dlq"}: depth only, no receive/delete
    actions   = ["sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
    resources = [var.dlq_arn]
  }
  statement {
    sid       = "EncryptMessages"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "api" {
  name               = "${var.name}-ticket-api"
  assume_role_policy = data.aws_iam_policy_document.trust["api"].json
}

resource "aws_iam_role_policy" "api" {
  name   = "least-privilege"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

# ---------------------------------------------------------------- ticket-worker: consume only
data "aws_iam_policy_document" "worker" {
  statement {
    sid = "ConsumeNotifications"
    actions = [
      "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility",
      "sqs:GetQueueUrl", "sqs:GetQueueAttributes",
    ]
    resources = [var.queue_arn]
  }
  statement {
    sid       = "DecryptMessages"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "worker" {
  name               = "${var.name}-ticket-worker"
  assume_role_policy = data.aws_iam_policy_document.trust["worker"].json
}

resource "aws_iam_role_policy" "worker" {
  name   = "least-privilege"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

# ---------------------------------------------------------------- External Secrets Operator
# May read exactly two secrets: the app secret and the RDS-managed DB secret
data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid       = "ReadOpsDeskSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = var.readable_secret_arns
  }
  statement {
    sid       = "DecryptWithAppKey"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.trust["external_secrets"].json
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-opsdesk-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

# ---------------------------------------------------------------- Fluent Bit -> CloudWatch Logs (app log group only)
data "aws_iam_policy_document" "fluent_bit" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [var.app_log_group_arn, "${var.app_log_group_arn}:*"]
  }
  statement {
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "fluent_bit" {
  name               = "${var.name}-fluent-bit"
  assume_role_policy = data.aws_iam_policy_document.trust["fluent_bit"].json
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
