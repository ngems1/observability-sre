# One customer-managed key for the app's data at rest: RDS, SQS, Secrets Manager, CloudWatch Logs, SNS.
# (EKS secrets envelope encryption uses the key the EKS module creates.)

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name
}

data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_111:Key policy - "*" resource means "this key"; standard AWS key policy shape
  #checkov:skip=CKV_AWS_356:Key policy - "*" resource means "this key"; standard AWS key policy shape
  #checkov:skip=CKV_AWS_109:Key policy - account root keeps admin so IAM policies can delegate; standard AWS default
  # Account root keeps full control (standard key policy; IAM policies grant the rest)
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudWatch Logs must be allowed explicitly to use a CMK
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }

  # SNS (alarm topic) and CloudWatch alarms publishing to it
  statement {
    sid       = "CloudWatchAlarmsToEncryptedSns"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "app" {
  description             = "${var.name} application data (RDS, SQS, Secrets Manager, CloudWatch Logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "app" {
  name          = "alias/${var.name}-app"
  target_key_id = aws_kms_key.app.key_id
}
