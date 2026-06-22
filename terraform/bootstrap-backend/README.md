# Terraform backend bootstrap

This isolated configuration creates the S3 bucket used by the main Terraform stack. Its own small state remains local because a backend cannot create the bucket in which its state is stored.

## Create the backend bucket

```powershell
cd terraform/bootstrap-backend
terraform init
terraform apply
```

The bucket has versioning, server-side encryption, public-access blocking, bucket-owner enforcement, and a TLS-only policy. `prevent_destroy` protects it from accidental deletion.

## Migrate the existing main state

Return to the main Terraform directory:

```powershell
cd ..
Copy-Item backend.hcl.example backend.hcl
terraform init -migrate-state -backend-config=backend.hcl
```

When Terraform asks whether to copy the existing state to the S3 backend, answer `yes`.

Verify the migration before doing more infrastructure work:

```powershell
terraform state list
terraform plan
```

The main stack uses S3 native locking through `use_lockfile = true`; no DynamoDB lock table is required.

Keep the `bootstrap-backend/terraform.tfstate` file safe. Do not run `terraform destroy` here during normal application teardown—the remote state bucket must outlive the infrastructure whose state it stores.
