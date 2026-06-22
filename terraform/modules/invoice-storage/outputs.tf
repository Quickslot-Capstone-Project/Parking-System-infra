output "bucket_names" {
  value = { for environment, bucket in aws_s3_bucket.invoice : environment => bucket.id }
}

output "bucket_arns" {
  value = { for environment, bucket in aws_s3_bucket.invoice : environment => bucket.arn }
}

output "kms_key_arns" {
  value = { for environment, key in aws_kms_key.invoice : environment => key.arn }
}

output "kms_alias_arns" {
  value = { for environment, alias in aws_kms_alias.invoice : environment => alias.arn }
}
