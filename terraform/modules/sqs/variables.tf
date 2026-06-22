variable "project_name" { type = string }
variable "environments" { type = set(string) }
variable "tags" { type = map(string) }
variable "message_retention_seconds" {
  type    = number
  default = 345600
}
variable "visibility_timeout_seconds" {
  type    = number
  default = 120
}
variable "max_receive_count" {
  type    = number
  default = 3
}

