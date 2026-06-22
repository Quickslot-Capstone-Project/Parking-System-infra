provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "smart-parking"
      ManagedBy = "Terraform"
      Purpose   = "TerraformState"
    }
  }
}
