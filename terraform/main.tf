data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

module "vpc" {
  source = "./modules/vpc"

  name                 = local.name_prefix
  cluster_name         = local.cluster_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
  tags                 = local.common_tags
}

module "dynamodb" {
  source = "./modules/dynamodb"

  name_prefix                 = var.project_name
  point_in_time_recovery      = var.dynamodb_point_in_time_recovery
  deletion_protection_enabled = false
  tags                        = local.common_tags
}

module "invoice_storage" {
  source = "./modules/invoice-storage"

  project_name = var.project_name
  environments = toset(["dev", "prod"])
  account_id   = data.aws_caller_identity.current.account_id
  region       = "us-east-1"
  tags         = local.common_tags
}

module "invoice_email" {
  source = "./modules/invoice-email"

  enabled              = length(var.invoice_email_environments) > 0
  project_name         = var.project_name
  environments         = var.invoice_email_environments
  sender_email         = var.invoice_email_sender
  account_id           = data.aws_caller_identity.current.account_id
  region               = "us-east-1"
  invoice_bucket_names = module.invoice_storage.bucket_names
  invoice_bucket_arns  = module.invoice_storage.bucket_arns
  invoice_kms_key_arns = module.invoice_storage.kms_key_arns
  tags                 = local.common_tags
}

module "sqs" {
  source = "./modules/sqs"

  project_name = var.project_name
  environments = toset(["dev", "prod"])
  tags         = local.common_tags
}

module "eks" {
  source = "./modules/eks"

  cluster_name                 = local.cluster_name
  kubernetes_version           = var.kubernetes_version
  private_subnet_ids           = module.vpc.private_subnet_ids
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  node_instance_types          = var.node_instance_types
  node_capacity_type           = var.node_capacity_type
  node_desired_size            = var.node_desired_size
  node_min_size                = var.node_min_size
  node_max_size                = var.node_max_size
  tags                         = local.common_tags

  # Wait for all networking, including NAT routes, before EKS creates nodes.
  # On destroy, this reverses the order: EKS is removed before the VPC.
  depends_on = [module.vpc]
}

resource "aws_iam_role" "application" {
  name = "${local.name_prefix}-application-pod-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "application_dynamodb" {
  name = "${local.name_prefix}-dynamodb-access"
  role = aws_iam_role.application.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ApplicationTableAccess"
      Effect = "Allow"
      Action = [
        "dynamodb:BatchGetItem",
        "dynamodb:BatchWriteItem",
        "dynamodb:DeleteItem",
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:UpdateItem"
      ]
      Resource = values(module.dynamodb.table_arns)
    }]
  })
}

resource "aws_eks_pod_identity_association" "application" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.application_namespace
  service_account = var.application_service_account
  role_arn        = aws_iam_role.application.arn

  depends_on = [module.eks]
}

# Argo CD deploys the same application service account into isolated dev and
# prod namespaces. Keep the existing sps-ns association during migration.
resource "aws_eks_pod_identity_association" "application_environments" {
  for_each = toset(["dev", "prod"])

  cluster_name    = module.eks.cluster_name
  namespace       = each.value
  service_account = var.application_service_account
  role_arn        = aws_iam_role.application.arn

  depends_on = [module.eks]
}

# AWS Load Balancer Controller v3.4.0 permissions from the controller's
# official release policy. Pod Identity avoids long-lived AWS credentials and
# does not require service-account role annotations.
resource "aws_iam_policy" "load_balancer_controller" {
  name        = "${local.name_prefix}-aws-load-balancer-controller"
  description = "Permissions for the AWS Load Balancer Controller on EKS."
  policy      = file("${path.module}/policies/aws-load-balancer-controller-v3.4.0.json")
}

resource "aws_iam_role" "load_balancer_controller" {
  name = "${local.name_prefix}-aws-load-balancer-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller.arn

  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.load_balancer_controller
  ]
}

resource "aws_iam_role_policy" "application_bedrock" {
  name = "${local.name_prefix}-bedrock-nova"
  role = aws_iam_role.application.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeNovaPro"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:bedrock:us-east-1::foundation-model/amazon.nova-pro-v1:0"
      },
      {
        Sid      = "InvokeGroundedAssistantLambda"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.ai_assistant.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "application_invoice_storage" {
  name = "${local.name_prefix}-invoice-storage"
  role = aws_iam_role.application.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListInvoiceBuckets"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = values(module.invoice_storage.bucket_arns)
      },
      {
        Sid      = "ManageInvoiceObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = [for arn in values(module.invoice_storage.bucket_arns) : "${arn}/*"]
      },
      {
        Sid    = "UseInvoiceKMSKeys"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey"
        ]
        Resource = values(module.invoice_storage.kms_key_arns)
      }
    ]
  })
}

resource "aws_iam_role_policy" "application_sqs" {
  name = "${local.name_prefix}-sqs-access"
  role = aws_iam_role.application.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PublishAndConsumeApplicationEvents"
        Effect = "Allow"
        Action = [
          "sqs:ChangeMessageVisibility",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
          "sqs:SendMessage"
        ]
        Resource = values(module.sqs.queue_arns)
      },
      {
        Sid    = "UseSQSKeys"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ]
        Resource = values(module.sqs.kms_key_arns)
      }
    ]
  })
}

data "archive_file" "ai_assistant" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/ai-assistant"
  output_path = "${path.module}/.terraform/ai-assistant.zip"
}

resource "aws_iam_role" "ai_assistant_lambda" {
  name = "${local.name_prefix}-ai-assistant-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ai_assistant_basic" {
  role       = aws_iam_role.ai_assistant_lambda.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ai_assistant_data" {
  name = "${local.name_prefix}-ai-assistant-data"
  role = aws_iam_role.ai_assistant_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadParkingContext"
        Effect = "Allow"
        Action = ["dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [
          module.dynamodb.table_arns["bookings"],
          module.dynamodb.table_arns["slots"]
        ]
      },
      {
        Sid      = "InvokeNovaPro"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "arn:${data.aws_partition.current.partition}:bedrock:us-east-1::foundation-model/amazon.nova-pro-v1:0"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ai_assistant" {
  name              = "/aws/lambda/${local.name_prefix}-ai-assistant"
  retention_in_days = 14
}

resource "aws_lambda_function" "ai_assistant" {
  function_name = "${local.name_prefix}-ai-assistant"
  role          = aws_iam_role.ai_assistant_lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 30

  filename         = data.archive_file.ai_assistant.output_path
  source_code_hash = data.archive_file.ai_assistant.output_base64sha256

  environment {
    variables = {
      BOOKINGS_TABLE   = module.dynamodb.table_names["bookings"]
      SLOTS_TABLE      = module.dynamodb.table_names["slots"]
      BEDROCK_REGION   = "us-east-1"
      BEDROCK_MODEL_ID = "amazon.nova-pro-v1:0"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ai_assistant_basic,
    aws_iam_role_policy.ai_assistant_data,
    aws_cloudwatch_log_group.ai_assistant
  ]
}
