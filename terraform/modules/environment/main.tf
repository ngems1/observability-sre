# One application environment (dev or prod) inside the shared cluster.
# Everything an environment owns is separate from the other environment:
#   data      own SQS queue + DLQ, own RDS instance (own credentials), own app secret
#   identity  own IAM roles for its pods (api, worker, secrets reader), trusted ONLY for its namespace
#   ops       own CloudWatch log group, Logs Insights queries and alarms
# What is shared (cluster, VPC, KMS key, ECR, monitoring) comes in as inputs.

locals {
  tags        = merge(var.tags, { Env = var.environment })
  oidc_issuer = replace(var.oidc_issuer_url, "https://", "")
  # Kubernetes service accounts (rendered by the Helm chart, release name = var.app_release)
  service_accounts = {
    api     = "system:serviceaccount:${var.namespace}:${var.app_release}-api"
    worker  = "system:serviceaccount:${var.namespace}:${var.app_release}-worker"
    secrets = "system:serviceaccount:${var.namespace}:${var.app_release}-secrets"
  }
}

# ------------------------------------------------------------------ data
module "sqs" {
  source = "../sqs"

  name_prefix = var.name
  kms_key_arn = var.kms_key_arn
  tags        = local.tags
}

module "rds" {
  source = "../rds"

  name                      = var.name
  vpc_id                    = var.vpc_id
  db_subnet_group_name      = var.db_subnet_group_name
  allowed_security_group_id = var.node_security_group_id
  kms_key_arn               = var.kms_key_arn
  instance_class            = var.db_instance_class
  allocated_storage_gb      = var.db_allocated_storage_gb
  multi_az                  = var.db_multi_az
  performance_insights      = var.db_performance_insights
  log_retention_days        = var.log_retention_days
  tags                      = local.tags
}

module "secrets" {
  source = "../secrets"

  name              = var.name
  kms_key_arn       = var.kms_key_arn
  slack_webhook_url = var.slack_webhook_url
  tags              = local.tags
}

# ------------------------------------------------------------------ identity (IRSA, this namespace only)
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

# ticket-api: publish to this environment's queue, read its DLQ depth
data "aws_iam_policy_document" "api" {
  statement {
    sid       = "PublishNotifications"
    actions   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
    resources = [module.sqs.queue_arn]
  }
  statement {
    sid       = "ReadDlqDepth" # opsdesk_queue_messages{queue="dlq"}: depth only, no receive/delete
    actions   = ["sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
    resources = [module.sqs.dlq_arn]
  }
  statement {
    sid       = "EncryptMessages"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

# ticket-worker: consume this environment's queue
data "aws_iam_policy_document" "worker" {
  statement {
    sid = "ConsumeNotifications"
    actions = [
      "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility",
      "sqs:GetQueueUrl", "sqs:GetQueueAttributes",
    ]
    resources = [module.sqs.queue_arn]
  }
  statement {
    sid       = "DecryptMessages"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

# External Secrets reads exactly this environment's two secrets, through a service account in its namespace
data "aws_iam_policy_document" "secrets" {
  statement {
    sid       = "ReadEnvironmentSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [module.secrets.secret_arn, module.rds.master_user_secret_arn]
  }
  statement {
    sid       = "DecryptWithAppKey"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

locals {
  role_policies = {
    api     = data.aws_iam_policy_document.api.json
    worker  = data.aws_iam_policy_document.worker.json
    secrets = data.aws_iam_policy_document.secrets.json
  }
}

resource "aws_iam_role" "app" {
  for_each           = local.role_policies
  name               = "${var.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json
  tags               = local.tags
}

resource "aws_iam_role_policy" "app" {
  for_each = local.role_policies
  name     = "least-privilege"
  role     = aws_iam_role.app[each.key].id
  policy   = each.value
}

# ------------------------------------------------------------------ ops: logs, queries, alarms
resource "aws_cloudwatch_log_group" "app" {
  #checkov:skip=CKV_AWS_338:7-day retention is a deliberate cost decision (docs/cost.md)
  # Fluent Bit writes each namespace to /<namespace>/application
  name              = "/${var.namespace}/application"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = local.tags
}

# Logs Insights queries (Fluent Bit puts the app's JSON fields under "data")
resource "aws_cloudwatch_query_definition" "by_trace" {
  name            = "${var.name}/logs-for-trace-id"
  log_group_names = [aws_cloudwatch_log_group.app.name]
  query_string = <<-EOT
    fields @timestamp, data.service, data.level, data.message, data.ticket_id, data.route, data.status, data.duration_ms
    | filter data.trace_id = "PASTE_TRACE_ID_HERE"
    | sort @timestamp asc
  EOT
}

resource "aws_cloudwatch_query_definition" "errors" {
  name            = "${var.name}/errors-last-hour"
  log_group_names = [aws_cloudwatch_log_group.app.name]
  query_string = <<-EOT
    fields @timestamp, data.service, data.message, data.dependency, data.error_kind, data.trace_id, data.route, data.status, data.error
    | filter data.level = "ERROR" or data.status >= 500
    | sort @timestamp desc
    | limit 100
  EOT
}

# Out-of-cluster alarms: they still email if the cluster (and Alertmanager) is down
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name}-dlq-not-empty"
  alarm_description   = "${var.environment}: notifications landed in the DLQ. Runbook: docs/runbook.md#opsdeskdlqnotempty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = module.sqs.dlq_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  alarm_name          = "${var.name}-queue-age-high"
  alarm_description   = "${var.environment}: oldest notification waiting > 5 min (worker down or stuck). Runbook: docs/runbook.md#opsdeskworkerdown"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = module.sqs.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name}-rds-cpu-high"
  alarm_description   = "${var.environment}: RDS CPU > 80% for 10 min. Runbook: docs/runbook.md#opsdeskdatabaseslow"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = module.rds.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [var.sns_topic_arn]
  ok_actions          = [var.sns_topic_arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.name}-rds-free-storage-low"
  alarm_description   = "${var.environment}: RDS free storage < 2 GiB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = module.rds.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [var.sns_topic_arn]
  tags                = local.tags
}
