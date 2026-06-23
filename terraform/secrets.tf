resource "aws_secretsmanager_secret" "application" {
  name                    = local.application_secrets_manager_secret_name
  description             = "Sensitive runtime configuration for Smart Parking backend services."
  recovery_window_in_days = local.application_secrets_recovery_window_days

  tags = merge(local.common_tags, {
    Scope = "application-secrets"
  })
}

resource "aws_iam_role_policy" "application_secrets" {
  name = "${local.name_prefix}-application-secrets"
  role = aws_iam_role.application.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadApplicationSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.application.arn
      }
    ]
  })
}
