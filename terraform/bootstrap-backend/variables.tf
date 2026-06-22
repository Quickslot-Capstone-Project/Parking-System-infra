variable "state_bucket_name" {
  description = "Globally unique S3 bucket name used for Terraform state."
  type        = string
  default     = "smart-parking-terraform-state-533595510771-us-east-1"
}
