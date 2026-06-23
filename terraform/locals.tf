locals {
  name_prefix                              = "${var.project_name}-${var.environment}"
  cluster_name                             = "${local.name_prefix}-eks"
  application_secrets_manager_secret_name  = coalesce(var.application_secrets_manager_secret_name, var.payment_secrets_manager_secret_name, "${local.name_prefix}-application-secrets")
  application_secrets_recovery_window_days = var.application_secrets_recovery_window_in_days != null ? var.application_secrets_recovery_window_in_days : var.payment_secrets_recovery_window_in_days

  common_tags = merge({
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }, var.additional_tags)
}
