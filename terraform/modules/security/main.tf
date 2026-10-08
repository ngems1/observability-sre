# Day 4 detective controls. Off by default (they bill after free trials); turn on with the repository
# variables ENABLE_GUARDDUTY / ENABLE_SECURITYHUB / ENABLE_INSPECTOR / ENABLE_CLOUDTRAIL = true.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_guardduty_detector" "main" {
  #checkov:skip=CKV2_AWS_3:Single-account demo, no AWS Organization
  count  = var.enable_guardduty ? 1 : 0
  enable = true
}

# EKS audit log + runtime monitoring for the cluster
resource "aws_guardduty_detector_feature" "eks_audit" {
  count       = var.enable_guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.main[0].id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "runtime" {
  count       = var.enable_guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.main[0].id
  name        = "RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}

resource "aws_securityhub_account" "main" {
  count                    = var.enable_securityhub ? 1 : 0
  enable_default_standards = false
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  count         = var.enable_securityhub ? 1 : 0
  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

# Inspector scans the ECR images (and EC2 nodes) for CVEs
resource "aws_inspector2_enabler" "main" {
  count          = var.enable_inspector ? 1 : 0
  account_ids    = [local.account_id]
  resource_types = ["ECR", "EC2"]
}

# ---------------------------------------------------------------- CloudTrail (management events)
resource "aws_s3_bucket" "trail" {
  #checkov:skip=CKV_AWS_18:Access logging for the trail bucket needs another bucket; out of demo scope
  #checkov:skip=CKV_AWS_144:No cross-region replication in the demo
  #checkov:skip=CKV2_AWS_62:No event consumers
  count         = var.enable_cloudtrail ? 1 : 0
  bucket        = "${var.name}-cloudtrail-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count                   = var.enable_cloudtrail ? 1 : 0
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  rule {
    id     = "expire-30-days"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "trail" {
  count = var.enable_cloudtrail ? 1 : 0
  statement {
    sid       = "AclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
  statement {
    sid       = "Write"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail[0].arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  policy = data.aws_iam_policy_document.trail[0].json
}

resource "aws_cloudtrail" "main" {
  #checkov:skip=CKV2_AWS_10:Trail goes to S3 only (CloudWatch delivery doubles log cost); query with Athena if needed
  count                         = var.enable_cloudtrail ? 1 : 0
  name                          = var.name
  s3_bucket_name                = aws_s3_bucket.trail[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  depends_on                    = [aws_s3_bucket_policy.trail]
}
