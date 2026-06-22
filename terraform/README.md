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
