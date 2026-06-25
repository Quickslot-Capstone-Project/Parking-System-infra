variable "cluster_name" { type = string }
variable "kubernetes_version" {
  type     = string
  default  = null
  nullable = true
}
variable "private_subnet_ids" { type = list(string) }
variable "endpoint_public_access" { type = bool }
variable "endpoint_public_access_cidrs" { type = list(string) }
variable "node_instance_types" { type = list(string) }
variable "node_capacity_type" { type = string }
variable "node_desired_size" { type = number }
variable "node_min_size" { type = number }
variable "node_max_size" { type = number }
variable "admin_principal_arns" {
  type    = set(string)
  default = []
}
variable "tags" { type = map(string) }
