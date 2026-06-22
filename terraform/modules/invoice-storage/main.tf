locals {
  bucket_names = {
    for environment in var.environments :
    environment => "${var.project_name}-${environment}-invoices-${var.account_id}-${var.region}"
  }
}

resource "aws_kms_key" "invoice" {
  for_each = var.environments

  description             = "KMS key for ${var.project_name} ${each.value} payment invoices"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = merge(var.tags, {
    Name        = "${var.project_name}-${each.value}-invoices"
    Environment = each.value
  })
}

resource "aws_kms_alias" "invoice" {
  for_each = var.environments

  name          = "alias/${var.project_name}-${each.value}-invoices"
  target_key_id = aws_kms_key.invoice[each.value].key_id
}

resource "aws_s3_bucket" "invoice" {
  for_each = var.environments

  bucket        = local.bucket_names[each.value]
  force_destroy = false

  tags = merge(var.tags, {
    Name        = local.bucket_names[each.value]
    Environment = each.value
    DataType    = "PaymentInvoices"
  })
}

resource "aws_s3_bucket_versioning" "invoice" {
  for_each = var.environments

  bucket = aws_s3_bucket.invoice[each.value].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "invoice" {
  for_each = var.environments

  bucket = aws_s3_bucket.invoice[each.value].id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.invoice[each.value].arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "invoice" {
  for_each = var.environments

  bucket = aws_s3_bucket.invoice[each.value].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "invoice" {
  for_each = var.environments

  bucket = aws_s3_bucket.invoice[each.value].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "invoice" {
  for_each = var.environments

  bucket = aws_s3_bucket.invoice[each.value].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.invoice[each.value].arn,
          "${aws_s3_bucket.invoice[each.value].arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid       = "DenyUploadsWithoutKMSEncryption"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.invoice[each.value].arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.invoice]
}
