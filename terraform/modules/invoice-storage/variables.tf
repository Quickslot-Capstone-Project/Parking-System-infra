variable "project_name" { type = string }
variable "environments" { type = set(string) }
variable "account_id" { type = string }
variable "region" { type = string }
variable "tags" { type = map(string) }
