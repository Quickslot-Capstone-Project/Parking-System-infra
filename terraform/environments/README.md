# Terraform environments

This folder keeps environment-specific backend and variable files while reusing
the existing root Terraform configuration in `terraform/`.

Run Terraform from the `terraform/` directory and select the environment files:

```powershell
terraform init -reconfigure -backend-config=.\environments\dev\backend.hcl
terraform plan -var-file=.\environments\dev\terraform.tfvars
terraform apply -var-file=.\environments\dev\terraform.tfvars
```

For production:

```powershell
terraform init -reconfigure -backend-config=.\environments\prod\backend.hcl
terraform plan -var-file=.\environments\prod\terraform.tfvars
terraform apply -var-file=.\environments\prod\terraform.tfvars
```

Each environment uses a different remote state key. Keep CIDR ranges and names
different between environments to avoid AWS resource collisions.
