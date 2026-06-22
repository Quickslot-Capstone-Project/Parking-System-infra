data "aws_partition" "current" {}

locals {
  active_environments = var.enabled ? var.environments : toset([])
}

resource "aws_sesv2_email_identity" "sender" {
  count = trimspace(var.sender_email) != "" ? 1 : 0

  email_identity = var.sender_email
}

resource "terraform_data" "validate_sender" {
  count = var.enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = trimspace(var.sender_email) != ""
      error_message = "invoice_email_sender must be set when invoice email delivery is enabled."
    }
  }
}

resource "aws_kms_key" "queue" {
  for_each = local.active_environments

  description             = "KMS key for ${var.project_name} ${each.value} invoice email queue"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowS3ToEncryptQueueMessages"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = var.account_id }
          ArnLike      = { "aws:SourceArn" = var.invoice_bucket_arns[each.value] }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${each.value}-invoice-email"
    Environment = each.value
  })
}

resource "aws_kms_alias" "queue" {
  for_each = local.active_environments

  name          = "alias/${var.project_name}-${each.value}-invoice-email"
  target_key_id = aws_kms_key.queue[each.value].key_id
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.active_environments

  name                              = "${var.project_name}-${each.value}-invoice-email-dlq"
  message_retention_seconds         = 1209600
  kms_master_key_id                 = aws_kms_key.queue[each.value].arn
  kms_data_key_reuse_period_seconds = 300

  tags = merge(var.tags, {
    Environment = each.value
    QueueType   = "InvoiceEmailDLQ"
  })
}

resource "aws_sqs_queue" "email" {
  for_each = local.active_environments

  name                              = "${var.project_name}-${each.value}-invoice-email"
  message_retention_seconds         = 345600
  visibility_timeout_seconds        = 180
  receive_wait_time_seconds         = 20
  kms_master_key_id                 = aws_kms_key.queue[each.value].arn
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.value].arn
    maxReceiveCount     = 3
  })

  tags = merge(var.tags, {
    Environment = each.value
    QueueType   = "InvoiceEmail"
  })
}

resource "aws_sqs_queue_policy" "allow_s3" {
  for_each = local.active_environments

  queue_url = aws_sqs_queue.email[each.value].url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowInvoiceBucketNotifications"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.email[each.value].arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnEquals    = { "aws:SourceArn" = var.invoice_bucket_arns[each.value] }
      }
    }]
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = local.active_environments

  queue_url = aws_sqs_queue.dlq[each.value].url
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.email[each.value].arn]
  })
}

resource "aws_dynamodb_table" "delivery" {
  for_each = local.active_environments

  name         = "${var.project_name}-${each.value}-invoice-email-deliveries"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "deliveryId"

  attribute {
    name = "deliveryId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(var.tags, {
    Environment = each.value
    DataType    = "InvoiceEmailDelivery"
  })
}

data "archive_file" "lambda" {
  count = var.enabled ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.root}/.terraform/invoice-email.zip"
}

resource "aws_iam_role" "lambda" {
  for_each = local.active_environments

  name = "${var.project_name}-${each.value}-invoice-email-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  for_each = local.active_environments

  role       = aws_iam_role.lambda[each.value].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.active_environments

  name = "${var.project_name}-${each.value}-invoice-email"
  role = aws_iam_role.lambda[each.value].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeInvoiceEmailQueue"
        Effect = "Allow"
        Action = [
          "sqs:ChangeMessageVisibility",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.email[each.value].arn
      },
      {
        Sid      = "DecryptQueue"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.queue[each.value].arn
      },
      {
        Sid      = "ReadInvoice"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${var.invoice_bucket_arns[each.value]}/payment-invoices/*"
      },
      {
        Sid      = "DecryptInvoice"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.invoice_kms_key_arns[each.value]
      },
      {
        Sid      = "TrackDeliveries"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.delivery[each.value].arn
      },
      {
        Sid      = "SendInvoiceEmail"
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ses:FromAddress" = var.sender_email
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.active_environments

  name              = "/aws/lambda/${var.project_name}-${each.value}-invoice-email"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_lambda_function" "email" {
  for_each = local.active_environments

  function_name = "${var.project_name}-${each.value}-invoice-email"
  role          = aws_iam_role.lambda[each.value].arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 60

  filename         = data.archive_file.lambda[0].output_path
  source_code_hash = data.archive_file.lambda[0].output_base64sha256

  environment {
    variables = {
      DELIVERY_TABLE       = aws_dynamodb_table.delivery[each.value].name
      ENVIRONMENT          = each.value
      MAX_ATTACHMENT_BYTES = "8388608"
      SENDER_EMAIL         = var.sender_email
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
    aws_iam_role_policy_attachment.lambda_basic
  ]

  tags = var.tags
}

resource "aws_lambda_event_source_mapping" "email" {
  for_each = local.active_environments

  event_source_arn                   = aws_sqs_queue.email[each.value].arn
  function_name                      = aws_lambda_function.email[each.value].arn
  batch_size                         = 5
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}

resource "aws_s3_bucket_notification" "invoice" {
  for_each = local.active_environments

  bucket = var.invoice_bucket_names[each.value]

  queue {
    queue_arn     = aws_sqs_queue.email[each.value].arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "payment-invoices/"
    filter_suffix = ".pdf"
  }

  depends_on = [aws_sqs_queue_policy.allow_s3]
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = local.active_environments

  alarm_name          = "${var.project_name}-${each.value}-invoice-email-dlq-has-messages"
  alarm_description   = "Invoice email delivery messages reached the dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.value].name
  }

  tags = var.tags
}
