# CloudWatch side of observability (the in-cluster side is Prometheus/Grafana/Tempo in terraform/platform):
#   - app log group (Fluent Bit ships ticket-api / ticket-worker JSON logs here), short retention, KMS
#   - Logs Insights queries used in the runbook
#   - SNS topic + out-of-cluster alarms: they still fire if the cluster (and Alertmanager) is down
#   - AWS Budget on the project's cost allocation tag

resource "aws_cloudwatch_log_group" "app" {
  #checkov:skip=CKV_AWS_338:7-day retention is a deliberate cost decision (docs/cost.md); raise for compliance workloads
  name              = "/${var.project}/${var.environment}/application"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
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

# ---------------------------------------------------------------- alerting path outside the cluster
resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name}-dlq-not-empty"
  alarm_description   = "Notifications landed in the DLQ. Owner: platform on-call. Runbook: docs/runbook.md#opsdeskdlqnotempty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.dlq_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  alarm_name          = "${var.name}-queue-age-high"
  alarm_description   = "Oldest notification waiting > 5 min (worker down or stuck). Owner: platform on-call. Runbook: docs/runbook.md#opsdeskworkerdown"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = var.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name}-rds-cpu-high"
  alarm_description   = "RDS CPU > 80% for 10 min. Owner: database team. Runbook: docs/runbook.md#opsdeskdatabaseslow"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.db_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.name}-rds-free-storage-low"
  alarm_description   = "RDS free storage < 2 GiB. Owner: database team."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.db_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------- cost guardrail
resource "aws_budgets_budget" "project" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Counts only resources tagged Project=<project> once the tag is activated for cost allocation;
  # until then the filter matches nothing, so also watch the account total in Billing.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project)]
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value == 100 ? "FORECASTED" : "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}
