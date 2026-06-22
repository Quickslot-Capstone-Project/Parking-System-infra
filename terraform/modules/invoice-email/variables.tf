variable "enabled" {
  description = "Create and activate the invoice email delivery pipeline."
  type        = bool
  default     = false
}

variable "project_name" { type = string }
variable "environments" { type = set(string) }
variable "sender_email" { type = string }
variable "account_id" { type = string }
variable "region" { type = string }
variable "invoice_bucket_names" { type = map(string) }
variable "invoice_bucket_arns" { type = map(string) }
variable "invoice_kms_key_arns" { type = map(string) }
variable "tags" { type = map(string) }

