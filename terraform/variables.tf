variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
  default     = "smart-parking"
}

variable "environment" {
  description = "Environment name used in resource names and tags."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the custom VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Two public subnet CIDRs, one for each Availability Zone."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly two public subnet CIDRs are required."
  }
}

variable "private_subnet_cidrs" {
  description = "Two private subnet CIDRs for EKS worker nodes."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Exactly two private subnet CIDRs are required."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway to save development cost. False creates one per AZ."
  type        = bool
  default     = false
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Null uses the current AWS default."
  type        = string
  default     = null
  nullable    = true
}

variable "endpoint_public_access" {
  description = "Enable the public EKS Kubernetes API endpoint."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs permitted to access the public EKS API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "EC2 instance types for EKS managed worker nodes."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "EKS node capacity type."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_desired_size" {
  description = "Desired EKS worker node count."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum EKS worker node count."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum EKS worker node count."
  type        = number
  default     = 4
}

variable "dynamodb_point_in_time_recovery" {
  description = "Enable point-in-time recovery for the application tables."
  type        = bool
  default     = true
}

variable "application_namespace" {
  description = "Kubernetes namespace associated with the application IAM role."
  type        = string
  default     = "sps-ns"
}

variable "application_service_account" {
  description = "Kubernetes service account associated with the application IAM role."
  type        = string
  default     = "smart-parking-app"
}

variable "additional_tags" {
  description = "Additional tags for all supported resources."
  type        = map(string)
  default     = {}
}

variable "invoice_email_environments" {
  description = "Environments with active S3-to-SQS-to-Lambda invoice email delivery. Start empty, then enable dev before prod."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for environment in var.invoice_email_environments : contains(["dev", "prod"], environment)])
    error_message = "invoice_email_environments may contain only dev and prod."
  }
}

variable "invoice_email_sender" {
  description = "SES sender email identity in us-east-1. Required when invoice_email_environments is not empty."
  type        = string
  default     = ""
}

variable "application_secrets_manager_secret_name" {
  description = "Stable AWS Secrets Manager secret name for all backend service sensitive configuration. Null uses <project>-<environment>-application-secrets."
  type        = string
  default     = null
  nullable    = true
}

variable "application_secrets_recovery_window_in_days" {
  description = "Recovery window for the application secret. Null uses payment_secrets_recovery_window_in_days for backward compatibility."
  type        = number
  default     = null
  nullable    = true

  validation {
    condition = (
      var.application_secrets_recovery_window_in_days == null ||
      var.application_secrets_recovery_window_in_days == 0 ||
      (
        var.application_secrets_recovery_window_in_days >= 7 &&
        var.application_secrets_recovery_window_in_days <= 30
      )
    )
    error_message = "application_secrets_recovery_window_in_days must be null, 0, or between 7 and 30."
  }
}

variable "payment_secrets_manager_secret_name" {
  description = "Deprecated alias. Use application_secrets_manager_secret_name. If set, it overrides the default application secret name."
  type        = string
  default     = null
  nullable    = true
}

variable "payment_secrets_recovery_window_in_days" {
  description = "Deprecated alias. Use application_secrets_recovery_window_in_days. Use 0 for force-delete on terraform destroy so the same name can be recreated immediately."
  type        = number
  default     = 0

  validation {
    condition     = var.payment_secrets_recovery_window_in_days == 0 || (var.payment_secrets_recovery_window_in_days >= 7 && var.payment_secrets_recovery_window_in_days <= 30)
    error_message = "payment_secrets_recovery_window_in_days must be 0 or between 7 and 30."
  }
}
