# Encrypted invoice email delivery

The pipeline is disabled by default and makes no changes to EKS, Helm, or
Argo CD:

```text
S3 ObjectCreated -> encrypted SQS -> Lambda -> Amazon SES
```

The existing payment service stores the recipient email, booking ID, and
payment ID as encrypted invoice-object metadata. Lambda reads that metadata,
attaches the PDF, and sends it through SES. A DynamoDB delivery table limits
duplicate sends, while failed messages retry three times before reaching a
dead-letter queue.

## Prerequisites

Choose an address you control, such as `invoices@your-domain.com`. An SES email
identity requires verification from the mailbox. For production, prefer an SES
domain identity with DKIM and request SES production access; sandbox accounts
can send only to verified recipients.

## Create and verify the SES sender

First set only the sender in the real, gitignored `terraform.tfvars`. Keep the
environment set empty so no invoice events are processed yet:

```hcl
invoice_email_environments = []
invoice_email_sender       = "your-verified-address@example.com"
```

Then run:

```powershell
terraform plan
terraform apply
```

Open the SES verification email and approve the sender identity before testing.
Confirm its status in the SES console or with:

```powershell
aws sesv2 get-email-identity --email-identity "your-verified-address@example.com" --region us-east-1
```

## Enable dev

After verification, change only:

```hcl
invoice_email_environments = ["dev"]
```

Run `terraform plan` and `terraform apply` again. Create a new dev payment;
only newly uploaded invoice PDFs trigger delivery.

Verify:

```powershell
terraform output invoice_email_lambda_names
aws logs tail /aws/lambda/smart-parking-dev-invoice-email --follow --region us-east-1
aws sqs get-queue-attributes --queue-url (terraform output -json invoice_email_queue_urls | ConvertFrom-Json).dev --attribute-names All --region us-east-1
```

## Promote to prod

After dev delivery succeeds, change only:

```hcl
invoice_email_environments = ["dev", "prod"]
```

Review `terraform plan` and apply. No Kubernetes image or Argo CD sync is
required.

## Disable safely

Use an empty set and apply:

```hcl
invoice_email_environments = []
```

This removes the S3 event notifications before the Lambda and queues. Existing
invoice PDFs remain in their protected S3 buckets. Review any DLQ messages
before disabling because removing a queue also removes messages in it.
