output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "Custom VPC ID."
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnet_ids
  description = "Public subnet IDs."
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnet_ids
  description = "Private EKS subnet IDs."
}

output "eks_cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name."
}

output "dynamodb_table_names" {
  value       = module.dynamodb.table_names
  description = "Application DynamoDB table names."
}

output "configure_kubectl_command" {
  value       = "aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}"
  description = "Command that configures kubectl for the cluster."
}

output "aws_load_balancer_controller_role_arn" {
  value       = aws_iam_role.load_balancer_controller.arn
  description = "Pod Identity IAM role used by the AWS Load Balancer Controller."
}

output "application_bedrock_role_arn" {
  value       = aws_iam_role.application.arn
  description = "Existing application Pod Identity role extended with Amazon Bedrock Nova access."
}

output "ai_assistant_lambda_name" {
  value       = aws_lambda_function.ai_assistant.function_name
  description = "Lambda function that grounds Nova responses with live DynamoDB data."
}

output "invoice_bucket_names" {
  value       = module.invoice_storage.bucket_names
  description = "Environment-specific private S3 buckets for payment invoice PDFs."
}

output "invoice_kms_alias_arns" {
  value       = module.invoice_storage.kms_alias_arns
  description = "Environment-specific KMS alias ARNs used by payment-service."
}

output "sqs_queue_urls" {
  value       = module.sqs.queue_urls
  description = "Environment-specific notification and invoice queue URLs."
}

output "sqs_dead_letter_queue_arns" {
  value       = module.sqs.dlq_arns
  description = "Dead-letter queue ARNs for monitoring and redrive."
}

output "invoice_email_sender_identity_arn" {
  value       = module.invoice_email.sender_identity_arn
  description = "SES sender identity ARN. Null while invoice email delivery is disabled."
}

output "invoice_email_queue_urls" {
  value       = module.invoice_email.queue_urls
  description = "Dev and prod invoice email queue URLs. Empty while delivery is disabled."
}

output "invoice_email_lambda_names" {
  value       = module.invoice_email.lambda_names
  description = "Dev and prod invoice email Lambda names. Empty while delivery is disabled."
}
