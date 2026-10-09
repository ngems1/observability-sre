# Notification queue + dead-letter queue, both encrypted with the app CMK.
# maxReceiveCount must match OPSDESK_SQS_MAX_RECEIVE_COUNT in the Helm values.

resource "aws_sqs_queue" "dlq" {
  name                              = "${var.name_prefix}-notifications-dlq"
  message_retention_seconds         = 1209600 # 14 days to inspect and redrive
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 3600
  tags                              = var.tags
}

resource "aws_sqs_queue" "notifications" {
  name                              = "${var.name_prefix}-notifications"
  visibility_timeout_seconds        = 30
  message_retention_seconds         = 345600 # 4 days
  receive_wait_time_seconds         = 10     # long polling (fewer empty receives = lower cost)
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 3600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.notifications.arn]
  })
}

# Deny any non-TLS access to both queues
data "aws_iam_policy_document" "sqs_tls_only" {
  for_each = {
    main = aws_sqs_queue.notifications.arn
    dlq  = aws_sqs_queue.dlq.arn
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "tls_only" {
  for_each  = { main = aws_sqs_queue.notifications.id, dlq = aws_sqs_queue.dlq.id }
  queue_url = each.value
  policy    = data.aws_iam_policy_document.sqs_tls_only[each.key].json
}
