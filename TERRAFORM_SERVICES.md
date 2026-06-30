# Terraform services documentation

This document explains the main AWS services managed by this Terraform root
module for the Smart Parking infrastructure. It covers the AWS services
created, referenced, or granted access by the Terraform configuration:
Amazon VPC and EC2 networking, Route 53, Elastic Load Balancing, ACM,
CloudFront, AWS WAF, Amazon EKS, IAM, Secrets Manager, DynamoDB, S3, KMS,
SQS, Lambda, Bedrock, SES, CloudWatch, and ECR image pull access.

The Terraform root module is in `terraform/` and uses AWS region `us-east-1`.
Common names are built from:

```text
<project_name>-<environment>
```

With the default variables, that prefix is:

```text
smart-parking-dev
```

## High-level request flow

For production web traffic, the intended flow is:

```text
User -> Route 53 -> CloudFront with AWS WAF -> production ALB -> EKS services
```

Terraform creates the DNS zone, CloudFront distribution, WAF web ACL, EKS
cluster, node group, IAM roles, Pod Identity associations, SQS queues, and
supporting storage, encryption, monitoring, and security resources.

The Kubernetes application and its Ingress create the production ALB outside
this Terraform module. Terraform then uses that existing ALB as the CloudFront
origin.

## Important Terraform files

| Area | File or module | Purpose |
| --- | --- | --- |
| Root module | `main.tf` | Wires modules together and creates IAM roles, Pod Identity associations, Lambda, and app permissions. |
| Variables | `variables.tf` | Defines configurable settings such as domain, EKS node sizes, ALB name, and CloudFront behavior. |
| Outputs | `outputs.tf` | Exposes service IDs, names, ARNs, URLs, and helper commands after apply. |
| VPC | `modules/vpc/` | Creates the VPC, subnets, internet gateway, NAT gateways, and route tables. |
| Route 53 | `route53.tf` | Creates the public hosted zone and alias record. |
| CloudFront/WAF | `edge.tf` | Creates the CloudFront distribution and WAF web ACL. |
| EKS | `modules/eks/` | Creates the EKS cluster, node group, add-ons, IAM roles, and access entries. |
| DynamoDB | `modules/dynamodb/` | Creates application tables. |
| Invoice storage | `modules/invoice-storage/` | Creates encrypted private S3 buckets for invoice PDFs. |
| SQS | `modules/sqs/` | Creates application queues, dead-letter queues, KMS keys, and DLQ alarms. |
| Invoice email SQS | `modules/invoice-email/` | Optional S3-to-SQS-to-Lambda invoice email pipeline. |
| Secrets Manager | `secrets.tf` | Creates the application secret container and External Secrets access role. |
| Backend bootstrap | `bootstrap-backend/` | Creates the optional S3 bucket used for remote Terraform state. |

## Amazon VPC and EC2 networking

The VPC module provides the network foundation for EKS and Kubernetes-created
load balancers.

### What Terraform creates

Terraform creates one custom VPC with DNS support and DNS hostnames enabled.
With the default values, the VPC CIDR is:

```text
10.0.0.0/16
```

The module uses two Availability Zones from the current AWS region and creates:

```text
2 public subnets
2 private subnets
1 internet gateway
1 public route table
2 private route tables
1 or 2 NAT gateways
Elastic IP addresses for NAT gateways
Route table associations for all subnets
```

Default subnet CIDRs:

```hcl
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
```

Public subnets map public IP addresses on launch and route internet-bound
traffic through the internet gateway. Private subnets do not assign public IPs
and route outbound internet traffic through NAT.

### Load balancer subnet tags

The VPC module adds Kubernetes discovery tags:

```text
kubernetes.io/cluster/<cluster_name> = shared
kubernetes.io/role/elb = 1
kubernetes.io/role/internal-elb = 1
```

These tags allow the AWS Load Balancer Controller running in EKS to discover
which subnets can host public and internal load balancers.

### Cost and availability option

The `single_nat_gateway` variable controls NAT gateway count:

```hcl
single_nat_gateway = false
```

The default creates one NAT gateway per Availability Zone. Setting it to `true`
uses a single NAT gateway to reduce development cost, with less Availability
Zone isolation.

Useful outputs:

```text
vpc_id
public_subnet_ids
private_subnet_ids
```

## Route 53

Amazon Route 53 provides public DNS for the application domain.

### What Terraform creates

Terraform creates a standalone public hosted zone:

```text
quickslot.site
```

The hosted zone is controlled by:

```hcl
route53_zone_enabled = true
domain_name          = "quickslot.site"
```

When both Route 53 and the edge stack are enabled, Terraform also creates an
`A` alias record for the root domain:

```text
quickslot.site -> CloudFront distribution
```

The alias points to the CloudFront distribution domain name and hosted zone ID.
Because it is an alias record, it does not need a fixed IP address.

### Operational notes

After `terraform apply`, copy the `route53_name_servers` output into the domain
registrar for `quickslot.site`. DNS will not resolve through this hosted zone
until the registrar is delegated to those Route 53 name servers.

Useful outputs:

```text
route53_zone_id
route53_name_servers
```

The current Terraform creates an `A` alias record for the domain. The
CloudFront distribution itself has IPv6 enabled, but there is no separate
Route 53 `AAAA` alias record in the current configuration.

## Elastic Load Balancing

Elastic Load Balancing is represented by the production Application Load
Balancer that the Kubernetes Ingress creates. Terraform does not create this
ALB directly, but the edge stack depends on it as the CloudFront origin.

### How Terraform uses the ALB

When `edge_enabled = true`, Terraform resolves the production ALB in one of two
ways:

```hcl
prod_alb_dns_name = null
prod_alb_name     = "smart-parking-prod-alb"
```

If `prod_alb_dns_name` is set, Terraform uses that hostname directly. If it is
null, Terraform looks up an existing ALB named `smart-parking-prod-alb`.

The ALB is expected to be created by the AWS Load Balancer Controller from the
production Kubernetes Ingress.

### Operational notes

Create or verify the production Ingress before applying the CloudFront edge
resources. If the ALB does not exist and `prod_alb_dns_name` is not set,
Terraform cannot build the CloudFront origin.

The AWS Load Balancer Controller IAM policy and Pod Identity association are
managed in `main.tf`, but the actual ALB lifecycle is driven by Kubernetes.

## AWS Certificate Manager

AWS Certificate Manager provides the TLS certificate used by CloudFront for the
public application domain.

### How Terraform uses ACM

Terraform looks up an existing issued ACM certificate when:

```hcl
edge_enabled = true
```

The certificate domain is:

```hcl
cloudfront_certificate_domain_name
```

If that value is null, Terraform uses:

```hcl
domain_name
```

With the default configuration, the certificate must cover:

```text
quickslot.site
```

### Operational notes

CloudFront requires the certificate to exist in `us-east-1`. Terraform only
looks up an issued certificate; it does not create or validate the certificate
in this repo.

## CloudFront

Amazon CloudFront is the public edge entry point for the production
application. It terminates viewer TLS, redirects HTTP viewers to HTTPS, and
forwards traffic to the production ALB created by the Kubernetes Ingress.

### What Terraform creates

Terraform creates one CloudFront distribution when:

```hcl
edge_enabled = true
```

The distribution uses:

```text
Origin: production ALB
Alias: quickslot.site by default
Viewer protocol policy: redirect-to-https
Origin protocol policy: http-only by default
Cache policy: Managed-CachingDisabled
Origin request policy: Managed-AllViewerExceptHostHeader
Allowed methods: DELETE, GET, HEAD, OPTIONS, PATCH, POST, PUT
Cached methods: GET, HEAD, OPTIONS
Compression: enabled
IPv6: enabled
Geo restriction: none
```

The origin ALB is resolved in one of two ways:

1. Prefer setting `prod_alb_dns_name` explicitly from the Kubernetes Ingress.
2. If `prod_alb_dns_name` is null, Terraform looks up an ALB named
   `smart-parking-prod-alb`.

The related variables are:

```hcl
prod_alb_name       = "smart-parking-prod-alb"
prod_alb_dns_name   = null
cloudfront_aliases  = []
```

When `cloudfront_aliases` is empty, Terraform uses `domain_name` as the alias.

### Certificate requirement

CloudFront requires an issued ACM certificate in `us-east-1` for the configured
alias. Terraform looks up the most recent issued certificate for:

```hcl
cloudfront_certificate_domain_name
```

If that variable is null, it uses:

```hcl
domain_name
```

For the default configuration, the certificate must cover:

```text
quickslot.site
```

### Operational notes

Before applying the edge stack, confirm that the production ALB exists. The
current README suggests reading it from Kubernetes:

```powershell
kubectl get ingress smart-parking-prod-alb -n prod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Useful outputs:

```text
cloudfront_distribution_id
cloudfront_domain_name
cloudfront_aliases
```

## AWS WAF

AWS WAF protects the public CloudFront distribution with managed rule groups.
The web ACL is attached directly to CloudFront.

### What Terraform creates

Terraform creates a CloudFront-scoped WAFv2 web ACL when:

```hcl
edge_enabled = true
```

The ACL name follows:

```text
<project_name>-<environment>-cloudfront-waf
```

With default values:

```text
smart-parking-dev-cloudfront-waf
```

The default action is `allow`, and AWS managed rules evaluate requests against
known unwanted patterns using AWS-managed rule actions.

Configured managed rule groups:

| Priority | Rule group | Purpose |
| --- | --- | --- |
| 10 | `AWSManagedRulesAmazonIpReputationList` | Helps block traffic from IP addresses with poor AWS reputation signals. |
| 20 | `AWSManagedRulesCommonRuleSet` | Covers common web exploits and unsafe request patterns. |
| 30 | `AWSManagedRulesKnownBadInputsRuleSet` | Blocks request inputs commonly associated with malicious activity. |

Each rule enables CloudWatch metrics and sampled requests.

Useful output:

```text
cloudfront_waf_web_acl_arn
```

### Operational notes

This WAF is scoped to `CLOUDFRONT`, so it is a global CloudFront protection
resource, not a regional ALB WAF. Traffic should reach the ALB through
CloudFront for this WAF to protect it.

## Amazon EKS

Amazon EKS runs the Kubernetes control plane and managed worker nodes for the
Smart Parking application.

### What Terraform creates

The EKS module creates:

```text
EKS cluster
Cluster IAM role
Cluster CloudWatch log group
Managed node group
Node IAM role
EKS access entries for admin principals
EKS managed add-ons
```

The default cluster name is:

```text
smart-parking-dev-eks
```

The module places EKS in the private subnets from the VPC module. The VPC module
creates two public subnets, two private subnets, internet gateway, NAT gateway
or gateways, and route tables. Public subnets are tagged for external load
balancers and private subnets are tagged for internal load balancers.

### Cluster settings

Important variables:

```hcl
kubernetes_version           = null
endpoint_public_access       = true
endpoint_public_access_cidrs = ["0.0.0.0/0"]
node_instance_types          = ["t3.medium"]
node_capacity_type           = "ON_DEMAND"
node_desired_size            = 2
node_min_size                = 2
node_max_size                = 4
```

When `kubernetes_version` is null, AWS chooses the default supported EKS
version at creation time.

The cluster has private endpoint access enabled. Public endpoint access is
controlled by `endpoint_public_access` and `endpoint_public_access_cidrs`.

Enabled control plane logs:

```text
api
audit
authenticator
controllerManager
scheduler
```

The log group retention is 30 days.

### Node group

Terraform creates a managed node group named:

```text
<cluster_name>-general
```

With default values:

```text
smart-parking-dev-eks-general
```

The node role receives these AWS managed policies:

```text
AmazonEKSWorkerNodePolicy
AmazonEKS_CNI_Policy
AmazonEC2ContainerRegistryPullOnly
```

The node group scaling values must satisfy:

```text
node_min_size <= node_desired_size <= node_max_size
```

### EKS add-ons

Terraform manages these EKS add-ons:

```text
coredns
eks-pod-identity-agent
kube-proxy
vpc-cni
```

These support Kubernetes DNS, Pod Identity, Kubernetes networking, and node
network proxy behavior.

### IAM and Pod Identity

Terraform creates Pod Identity associations so Kubernetes service accounts can
assume AWS IAM roles without long-lived AWS credentials.

Application Pod Identity:

```text
Namespace: sps-ns
Service account: smart-parking-app
```

During the dev/prod migration, Terraform also associates the same application
role with:

```text
Namespace: dev
Namespace: prod
Service account: smart-parking-app
```

The application role is granted access to:

```text
DynamoDB application tables
SQS application queues
SQS KMS keys
Invoice S3 buckets and KMS keys
Application Secrets Manager secret
Amazon Bedrock Nova Pro
AI assistant Lambda invocation
```

AWS Load Balancer Controller Pod Identity:

```text
Namespace: kube-system
Service account: aws-load-balancer-controller
```

External Secrets Operator Pod Identity:

```text
Namespace: external-secrets
Service account: external-secrets
```

### Useful commands and outputs

After apply, configure `kubectl` with:

```powershell
terraform output configure_kubectl_command
```

Or run the command value directly. With defaults:

```powershell
aws eks update-kubeconfig --region us-east-1 --name smart-parking-dev-eks
```

Useful outputs:

```text
eks_cluster_name
configure_kubectl_command
aws_load_balancer_controller_role_arn
application_bedrock_role_arn
```

## AWS IAM

AWS IAM provides the roles and policies used by EKS, EKS nodes, application
pods, Lambda functions, External Secrets Operator, and the AWS Load Balancer
Controller.

### What Terraform creates

Terraform creates IAM resources in the root module and in service modules:

```text
EKS cluster role
EKS node role
Application Pod Identity role
AWS Load Balancer Controller policy and role
External Secrets Operator Pod Identity role
AI assistant Lambda execution role
Invoice email Lambda execution roles
Inline policies for DynamoDB, SQS, S3, KMS, Secrets Manager, Lambda, SES, and Bedrock access
```

The EKS cluster role receives `AmazonEKSClusterPolicy`. The node role receives:

```text
AmazonEKSWorkerNodePolicy
AmazonEKS_CNI_Policy
AmazonEC2ContainerRegistryPullOnly
```

The AWS Load Balancer Controller policy is loaded from:

```text
policies/aws-load-balancer-controller-v3.4.0.json
```

### Pod Identity

Terraform uses EKS Pod Identity associations instead of long-lived AWS
credentials in Kubernetes workloads.

Main associations:

```text
sps-ns/smart-parking-app -> application role
dev/smart-parking-app -> application role
prod/smart-parking-app -> application role
kube-system/aws-load-balancer-controller -> load balancer controller role
external-secrets/external-secrets -> external secrets role
```

The Pod Identity trust policy allows:

```text
pods.eks.amazonaws.com
```

to assume the associated IAM roles.

### Operational notes

When adding new AWS service access for application pods, add it to the
application IAM role. When adding access for a Lambda function, update the
function-specific role instead.

Useful outputs:

```text
aws_load_balancer_controller_role_arn
application_bedrock_role_arn
```

## AWS Secrets Manager

Secrets Manager stores sensitive backend runtime configuration outside
Terraform state.

### What Terraform creates

Terraform creates one stable secret container:

```text
<project_name>-<environment>-application-secrets
```

With defaults:

```text
smart-parking-dev-application-secrets
```

Terraform creates the secret metadata and grants read access to:

```text
Application Pod Identity role
External Secrets Operator Pod Identity role
```

Terraform does not write the real secret values into state. Secret values such
as JWT secrets, internal API keys, payment keys, and seed passwords should be
added after apply with the AWS CLI or console.

### Recovery behavior

The default recovery behavior is controlled by:

```hcl
application_secrets_recovery_window_in_days = null
payment_secrets_recovery_window_in_days     = 0
```

With the default compatibility value, destroy force-deletes the secret so the
same name can be recreated immediately. Set a value from 7 to 30 days if
recovery protection is preferred.

Useful outputs:

```text
application_secrets_manager_secret_name
application_secrets_manager_secret_arn
```

## Amazon DynamoDB

DynamoDB stores the Smart Parking application data and optional invoice email
delivery tracking data.

### Application tables

The `modules/dynamodb` module creates five on-demand tables:

```text
smart-parking-users
smart-parking-slots
smart-parking-bookings
smart-parking-payments
smart-parking-notifications
```

Each table uses a string hash key:

| Logical table | Hash key |
| --- | --- |
| users | `userId` |
| slots | `slotId` |
| bookings | `bookingId` |
| payments | `paymentId` |
| notifications | `notificationId` |

The tables use:

```text
Billing mode: PAY_PER_REQUEST
Server-side encryption: enabled
Point-in-time recovery: enabled by default
Deletion protection: disabled in the root module
```

The application Pod Identity role can read and write these tables.

### Invoice email delivery table

When invoice email delivery is enabled, the `modules/invoice-email` module
creates one delivery tracking table per active environment:

```text
smart-parking-<environment>-invoice-email-deliveries
```

This table uses:

```text
Hash key: deliveryId
Billing mode: PAY_PER_REQUEST
Point-in-time recovery: enabled
```

Useful output:

```text
dynamodb_table_names
```

## Amazon S3

Amazon S3 is used for invoice PDF storage, invoice event notifications, and the
optional remote Terraform state backend.

### Invoice buckets

The `modules/invoice-storage` module creates private invoice buckets for:

```text
dev
prod
```

Bucket names follow:

```text
<project_name>-<environment>-invoices-<account_id>-<region>
```

With defaults and the current account variable source:

```text
smart-parking-dev-invoices-<account_id>-us-east-1
smart-parking-prod-invoices-<account_id>-us-east-1
```

Each invoice bucket has:

```text
Versioning enabled
KMS default encryption
S3 bucket keys enabled
Public access blocked
Bucket owner enforced object ownership
TLS-only bucket policy
Policy denying uploads without aws:kms encryption
```

The application Pod Identity role can list buckets and get or put invoice
objects.

### Invoice email S3 notifications

When invoice email delivery is enabled, the invoice email module attaches S3
bucket notifications for new PDF objects:

```text
Event: s3:ObjectCreated:*
Prefix: payment-invoices/
Suffix: .pdf
Target: encrypted SQS invoice email queue
```

### Terraform state bucket

The isolated `bootstrap-backend` Terraform configuration creates an S3 bucket
for remote Terraform state:

```text
smart-parking-terraform-state-533595510771-us-east-1
```

That bucket has:

```text
Versioning enabled
AES256 server-side encryption
Public access blocked
Bucket owner enforced object ownership
TLS-only bucket policy
prevent_destroy enabled
```

The main stack can use this bucket through `backend.hcl`. The bootstrap
configuration keeps its own local state because it creates the bucket that the
main stack may later use. The main stack uses S3 native locking through
`use_lockfile = true`, so this repo does not require a DynamoDB lock table for
Terraform state locking.

Useful outputs:

```text
invoice_bucket_names
```

The bootstrap module also outputs:

```text
state_bucket_name
state_bucket_arn
```

## AWS KMS

AWS KMS provides customer managed keys for encrypted SQS queues and invoice S3
objects.

### What Terraform creates

Terraform creates KMS keys and aliases for:

```text
Invoice S3 buckets
Application SQS queues
Optional invoice email SQS queues
```

Invoice storage aliases:

```text
alias/smart-parking-dev-invoices
alias/smart-parking-prod-invoices
```

SQS aliases:

```text
alias/smart-parking-dev-sqs
alias/smart-parking-prod-sqs
```

Invoice email aliases, when enabled:

```text
alias/smart-parking-<environment>-invoice-email
```

All configured KMS keys enable key rotation and use a 30 day deletion window.

### Permissions

The application Pod Identity role can use invoice and SQS keys needed by the
backend services. The invoice email Lambda role can decrypt queue messages and
invoice PDFs for the enabled environment.

Useful output:

```text
invoice_kms_alias_arns
```

## Amazon SQS

Amazon SQS provides durable asynchronous messaging for application events and
invoice-related processing.

### Main application queues

The `modules/sqs` module creates queues for each configured environment and
queue type.

Current root module environments:

```text
dev
prod
```

Queue types:

```text
notifications
invoices
```

This produces these main queues by default:

```text
smart-parking-dev-notifications
smart-parking-dev-invoices
smart-parking-prod-notifications
smart-parking-prod-invoices
```

Each main queue has a matching dead-letter queue:

```text
<queue-name>-dlq
```

### Queue settings

Default main queue settings:

```hcl
message_retention_seconds  = 345600
visibility_timeout_seconds = 120
receive_wait_time_seconds  = 20
max_receive_count          = 3
```

Important behavior:

```text
Messages are retained for 4 days by default.
Long polling is enabled with a 20 second receive wait.
Messages are sent to the DLQ after 3 failed receives by default.
DLQ messages are retained for 14 days.
```

### Encryption

The SQS module creates one KMS key per environment:

```text
alias/smart-parking-dev-sqs
alias/smart-parking-prod-sqs
```

Queues use the environment-specific KMS key. Key rotation is enabled, and the
KMS deletion window is 30 days.

The application IAM role has permissions to send, receive, delete, and change
visibility for the queues. It also has KMS permissions required to use the SQS
keys.

### Monitoring

Terraform creates a CloudWatch alarm for each dead-letter queue. The alarm
fires when the DLQ has visible messages:

```text
ApproximateNumberOfMessagesVisible > 0
```

The alarm treats missing data as not breaching.

Useful outputs:

```text
sqs_queue_urls
sqs_dead_letter_queue_arns
```

### Optional invoice email queues

The separate `modules/invoice-email` module can create an invoice email
pipeline:

```text
S3 ObjectCreated -> encrypted SQS -> Lambda -> Amazon SES
```

It is disabled by default because:

```hcl
invoice_email_environments = []
```

When enabled for an environment, it creates:

```text
smart-parking-<environment>-invoice-email
smart-parking-<environment>-invoice-email-dlq
```

Those queues receive S3 notifications for new invoice PDF objects under:

```text
payment-invoices/*.pdf
```

The Lambda consumer retries failed messages and uses partial batch failure
reporting. Messages move to the DLQ after three failed receives.

For the full invoice email enablement process, see `INVOICE_EMAIL.md`.

## AWS Lambda

AWS Lambda is used for the AI assistant helper and for the optional invoice
email delivery pipeline.

### AI assistant Lambda

The root module packages and creates one Lambda function from:

```text
lambda/ai-assistant
```

Function name:

```text
<project_name>-<environment>-ai-assistant
```

With defaults:

```text
smart-parking-dev-ai-assistant
```

Runtime configuration:

```text
Runtime: nodejs22.x
Architecture: arm64
Memory: 512 MB
Timeout: 30 seconds
Log retention: 14 days
```

The function receives environment variables for:

```text
BOOKINGS_TABLE
SLOTS_TABLE
BEDROCK_REGION
BEDROCK_MODEL_ID
```

Its IAM role can read the bookings and slots DynamoDB tables and invoke Amazon
Bedrock Nova Pro.

### Invoice email Lambda

When invoice email delivery is enabled, the invoice email module packages and
creates one Lambda function per active environment:

```text
smart-parking-<environment>-invoice-email
```

Runtime configuration:

```text
Runtime: nodejs22.x
Architecture: arm64
Memory: 512 MB
Timeout: 60 seconds
Batch size: 5 SQS messages
Maximum batching window: 5 seconds
Partial batch failures: enabled
Log retention: 14 days
```

The function consumes SQS messages, reads invoice PDFs from S3, tracks delivery
state in DynamoDB, and sends emails through SES.

Useful outputs:

```text
ai_assistant_lambda_name
invoice_email_lambda_names
```

## Amazon Bedrock

Amazon Bedrock is used for AI assistant responses through Amazon Nova Pro.

### What Terraform grants

Terraform does not create a Bedrock model. It grants permission to invoke this
foundation model in `us-east-1`:

```text
amazon.nova-pro-v1:0
```

The application Pod Identity role can:

```text
bedrock:InvokeModel
bedrock:InvokeModelWithResponseStream
```

The AI assistant Lambda role can also invoke the same model.

### Operational notes

The AWS account must have access to the model in Amazon Bedrock. If model access
is not enabled in the account or region, IAM permission alone is not enough for
successful invocation.

## Amazon SES

Amazon SES is used only by the optional invoice email pipeline.

### What Terraform creates

The invoice email module can create an SESv2 email identity when
`invoice_email_sender` is set:

```hcl
invoice_email_sender = "sender@example.com"
```

When invoice email delivery is enabled, Lambda receives permission to send mail
from that address:

```text
ses:SendEmail
ses:SendRawEmail
```

The IAM policy restricts sending by `ses:FromAddress`.

### Operational notes

SES email identities require verification before they can send email. In a
sandbox SES account, recipients must also be verified unless production access
has been approved.

Useful output:

```text
invoice_email_sender_identity_arn
```

## Amazon CloudWatch

CloudWatch is used for logs and alarms across the stack.

### Log groups

Terraform creates CloudWatch log groups for:

```text
EKS control plane logs
AI assistant Lambda logs
Invoice email Lambda logs, when enabled
```

Retention periods:

```text
EKS control plane: 30 days
Lambda functions: 14 days
```

### Metric alarms

Terraform creates CloudWatch alarms for SQS dead-letter queues. An alarm fires
when visible messages exist in a DLQ:

```text
Namespace: AWS/SQS
Metric: ApproximateNumberOfMessagesVisible
Statistic: Maximum
Threshold: greater than 0
Period: 300 seconds
Evaluation periods: 1
Missing data: notBreaching
```

Configured alarm groups:

```text
Application SQS DLQs
Optional invoice email DLQs
```

## Amazon ECR

Amazon ECR is referenced through the EKS node IAM permissions.

Terraform does not create ECR repositories in this repo. It attaches the AWS
managed policy:

```text
AmazonEC2ContainerRegistryPullOnly
```

to the EKS node role so worker nodes can pull container images from ECR.

If application images are hosted in ECR, repository creation and image pushes
are handled outside this Terraform stack.

## AWS account and region lookups

Terraform also reads AWS account and region metadata to build names, ARNs, and
environment-specific resources.

Data sources used:

```text
aws_caller_identity
aws_partition
aws_availability_zones
```

These do not create infrastructure. They provide the current AWS account ID,
partition, and available Availability Zones for the configured provider region.

## Apply and destroy notes

Normal lifecycle:

```powershell
terraform init
terraform plan
terraform apply
```

Destroy order matters when Kubernetes-created load balancers exist. Remove the
application Ingress and allow the AWS Load Balancer Controller to delete the ALB
before destroying Terraform resources. Otherwise, VPC, subnet, or security group
deletion can fail because AWS resources created by Kubernetes still depend on
them.

## Quick verification checklist

After applying the full stack, verify:

```text
VPC, public subnets, private subnets, NAT gateways, and route tables exist.
Route 53 name servers are configured at the registrar.
ACM certificate for quickslot.site is issued in us-east-1.
CloudFront distribution is deployed and has the expected aliases.
WAF web ACL is attached to the CloudFront distribution.
Production ALB exists and is reachable from CloudFront.
kubectl can connect to the EKS cluster.
EKS nodes are ready.
Application Pod Identity role can access DynamoDB, SQS, Secrets Manager, and related resources.
DynamoDB application tables exist.
Invoice S3 buckets are private, versioned, and KMS encrypted.
KMS aliases exist for invoice storage and SQS.
SQS queue URLs are available from Terraform outputs.
DLQ alarms exist for each queue.
AI assistant Lambda exists and has a CloudWatch log group.
If invoice email is enabled, SES identity is verified and invoice email Lambda can consume SQS messages.
```
