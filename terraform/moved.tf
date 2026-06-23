moved {
  from = aws_secretsmanager_secret.payment_service
  to   = aws_secretsmanager_secret.application
}

moved {
  from = aws_iam_role_policy.application_payment_secrets
  to   = aws_iam_role_policy.application_secrets
}
