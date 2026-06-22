output "sender_identity_arn" {
  value = try(aws_sesv2_email_identity.sender[0].arn, null)
}

output "queue_urls" {
  value = { for environment, queue in aws_sqs_queue.email : environment => queue.url }
}

output "lambda_names" {
  value = { for environment, function in aws_lambda_function.email : environment => function.function_name }
}

