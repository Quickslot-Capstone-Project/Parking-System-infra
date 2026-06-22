locals {
  queue_types = toset(["notifications", "invoices"])
  queues = {
    for pair in setproduct(var.environments, local.queue_types) :
    "${pair[0]}-${pair[1]}" => {
      environment = pair[0]
      type        = pair[1]
      name        = "${var.project_name}-${pair[0]}-${pair[1]}"
    }
  }
}

resource "aws_kms_key" "sqs" {
  for_each = var.environments

  description             = "KMS key for ${var.project_name} ${each.value} SQS queues"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${each.value}-sqs"
    Environment = each.value
  })
}

resource "aws_kms_alias" "sqs" {
  for_each = var.environments

  name          = "alias/${var.project_name}-${each.value}-sqs"
  target_key_id = aws_kms_key.sqs[each.value].key_id
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.queues

  name                              = "${each.value.name}-dlq"
  message_retention_seconds         = 1209600
  kms_master_key_id                 = aws_kms_key.sqs[each.value.environment].arn
  kms_data_key_reuse_period_seconds = 300

  tags = merge(var.tags, {
    Name        = "${each.value.name}-dlq"
    Environment = each.value.environment
    QueueType   = each.value.type
  })
}

resource "aws_sqs_queue" "this" {
  for_each = local.queues

  name                              = each.value.name
  message_retention_seconds         = var.message_retention_seconds
  visibility_timeout_seconds        = var.visibility_timeout_seconds
  receive_wait_time_seconds         = 20
  kms_master_key_id                 = aws_kms_key.sqs[each.value.environment].arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.tags, {
    Name        = each.value.name
    Environment = each.value.environment
    QueueType   = each.value.type
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = local.queues

  queue_url = aws_sqs_queue.dlq[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.this[each.key].arn]
  })
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  for_each = local.queues

  alarm_name          = "${each.value.name}-dlq-has-messages"
  alarm_description   = "Messages reached the ${each.value.name} dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.key].name
  }

  tags = var.tags
}

