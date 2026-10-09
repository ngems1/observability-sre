# Shared alerting and cost guardrail (per-environment log groups and alarms live in modules/environment;
# the in-cluster side is Prometheus/Grafana/Tempo in terraform/platform):
#   - SNS topic + email subscription for the out-of-cluster CloudWatch alarms of every environment
#   - AWS Budget on the project's cost allocation tag

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
