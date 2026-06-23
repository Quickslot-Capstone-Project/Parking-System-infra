# Smart Parking Terraform infrastructure

This root module creates the complete development infrastructure in `us-east-1`:

- One custom VPC across two Availability Zones.
- Two public subnets, an internet gateway, and a public route table.
- Two private subnets and private route tables.
- One NAT gateway per AZ by default; a single-NAT development option is available.
- An EKS control plane and managed worker nodes in private subnets.
- EKS managed networking, DNS, proxy, and Pod Identity add-ons.
- Five on-demand DynamoDB tables.
- EKS Pod Identity access from `sps-ns/smart-parking-app` to those tables.
- AWS Load Balancer Controller IAM permissions and Pod Identity association.
- Amazon Bedrock Nova Pro permission on the existing application Pod Identity role.
- A stable AWS Secrets Manager secret for backend service sensitive runtime configuration.

Terraform state is local as requested. Do not lose the `terraform.tfstate` file.

## First run

Terraform providers must be downloaded once:

```powershell
terraform init
terraform apply
```

Review the plan and enter `yes`. After initialization, the normal lifecycle is simply:

```powershell
terraform apply
terraform destroy
```

Never run `terraform destroy` while Helm-created Ingress load balancers still exist. Uninstall the application first, let the AWS Load Balancer Controller remove the ALB, then uninstall the controller and destroy Terraform. See `../eks-deployment/README.md` for the exact sequence.

## Application service secrets

Terraform creates one application Secrets Manager secret container and grants the application Pod Identity role permission to read it. It does not store the real payment gateway keys, JWT secret, internal API key, or other sensitive values in Terraform state.

The default secret name is stable and environment-specific:

```text
<project_name>-<environment>-application-secrets
```

For the default values this is:

```text
smart-parking-dev-application-secrets
```

After `terraform apply`, add or update the real secret value outside Terraform:

```powershell
aws secretsmanager put-secret-value `
  --secret-id smart-parking-dev-application-secrets `
  --secret-string '{\"JWT_SECRET\":\"replace-me\",\"INTERNAL_API_KEY\":\"replace-me\",\"RAZORPAY_KEY_ID\":\"rzp_live_xxxxx\",\"RAZORPAY_KEY_SECRET\":\"replace-me\",\"SEED_ADMIN_PASSWORD\":\"replace-me\",\"SEED_USER_PASSWORD\":\"replace-me\"}'
```

Set backend service environment variable `APPLICATION_SECRETS_MANAGER_SECRET_ID` to the Terraform output `application_secrets_manager_secret_name`. Services still work with the existing `.env` flow when that variable is not set.

By default, `application_secrets_recovery_window_in_days = 0`, so `terraform destroy` force-deletes this secret and a later `terraform apply` can recreate the same name immediately. Change it to `7` through `30` if you prefer AWS recovery protection.
