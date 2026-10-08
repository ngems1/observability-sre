# One-time bootstrap, run once from AWS CloudShell with your console identity (docs/aws.md, step 2):
#   1. the S3 bucket that holds the Terraform state of terraform/infra and terraform/platform
#   2. the GitHub OIDC trust + the role GitHub Actions assumes (no AWS keys anywhere)
# Everything after this runs from GitHub Actions. Local state is fine here (created once, rarely changed);
# keep a copy in the bucket: aws s3 cp terraform.tfstate s3://<state_bucket>/opsdesk/bootstrap.tfstate

module "github_oidc" {
  source = "../modules/github_oidc"

  github_repository    = var.github_repository
  role_name            = "${var.project}-github-deploy"
  create_oidc_provider = var.create_oidc_provider
}

# ------------------------------------------------------------------ Terraform state bucket
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:State bucket access logging needs a second bucket; demo scope (CloudTrail data events cover access if needed)
  #checkov:skip=CKV_AWS_144:Cross-region replication of Terraform state is out of scope for a demo; versioning protects against loss
  #checkov:skip=CKV2_AWS_62:No consumers for S3 event notifications on the state bucket
  bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
  # keep state if someone runs destroy here by mistake
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms" # AWS-managed key; state can contain secrets
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "tls_only" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
