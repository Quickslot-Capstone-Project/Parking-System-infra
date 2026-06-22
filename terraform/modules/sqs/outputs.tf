output "queue_urls" {
  value = {
    for key, queue in aws_sqs_queue.this : key => queue.url
  }
}

output "queue_arns" {
  value = {
    for key, queue in aws_sqs_queue.this : key => queue.arn
  }
}

output "dlq_arns" {
  value = {
    for key, queue in aws_sqs_queue.dlq : key => queue.arn
  }
}

output "kms_key_arns" {
  value = {
    for environment, key in aws_kms_key.sqs : environment => key.arn
  }
}

