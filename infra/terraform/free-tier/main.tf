terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  # Default credential chain: ~/.aws, envchain, or IAM role. No keys in this repo.
}

# ---------------------------------------------------------------------------
# VPC — PUBLIC SUBNETS ONLY. No NAT gateway (bills ~$32/mo), no ALB (~$25/mo).
# This is the free-tier-safe shape. See enterprise-reference.tf.
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "ml-platform-vpc" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "ml-platform-public-a" }
}
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true
  tags                    = { Name = "ml-platform-public-b" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "ml-platform-igw" }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "ml-platform-public-rt" }
}
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# S3 — lineage / audit / model artifacts. Versioned + Object Lock so you can
# answer "which data + which code produced this model." 5GB is free tier.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "ml_lineage" {
  bucket        = "${var.project}-lineage"
  force_destroy = true
}
resource "aws_s3_bucket_versioning" "ml_lineage" {
  bucket = aws_s3_bucket.ml_lineage.id
  versioning_configuration { status = "Enabled" }
}
# Object Lock: regulatory audit trail (WORM for model/data provenance).
# Depends on versioning being ENABLED first — object lock requires bucket
# versioning, and without this ordered dep Terraform can race them -> 409.
resource "aws_s3_bucket_object_lock_configuration" "ml_lineage" {
  bucket     = aws_s3_bucket.ml_lineage.id
  depends_on = [aws_s3_bucket_versioning.ml_lineage]
  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 365
    }
  }
}
resource "aws_s3_bucket_public_access_block" "ml_lineage" {
  bucket                  = aws_s3_bucket.ml_lineage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# ECS Fargate — the app container that calls Bedrock (managed model API).
# Fargate = no EC2 to manage; a small 0.5 vCPU/1GB task is only a few $/mo.
# (Enterprise swap: EKS or ECS-EC2 + HPA/Karpenter/spot — enterprise-reference.tf)
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "ml" {
  name = "${var.project}-ecs"
}

# Service-linked role AWSServiceRoleForECS — CreateService fails without it
# ("Unable to assume the service linked role"). AWS auto-creates it on first
# cluster create via console/SDK, but the provider won't race ahead; build it
# explicitly so apply doesn't 400.
resource "aws_iam_service_linked_role" "ecs" {
  aws_service_name = "ecs.amazonaws.com"
  description      = "Allows ECS to call AWS services on your behalf."
}

# ECR repo for the /v1->Bedrock proxy image. MUTABLE tags so the build script can
# push :latest. (ponytail: no lifecycle/scan policy until spend/security matters.)
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "MUTABLE"
  tags                 = { Name = "${var.project}-app" }
}

resource "aws_cloudwatch_log_group" "ml" {
  name              = "/ecs/${var.project}"
  retention_in_days = 7
}

resource "aws_iam_role" "ecs_execution" {
  name = "${var.project}-ecs-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
# Let the task call Bedrock, pull ECR, and write logs. Least privilege to start.
resource "aws_iam_role_policy" "ecs_execution" {
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = "*" },
      { Effect = "Allow", Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"], Resource = ["arn:aws:bedrock:*:*:inference-profile/*", "arn:aws:bedrock:${var.region}::foundation-model/*"] },
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.ml_lineage.arn}/*" }
    ]
  })
}

# Security group: let the /v1 proxy be reached on :8000 from the test IP only.
# ponytail: single allow-CIDR (var.ingress_cidr) for testing; tighten per
# deployment. This is a zero-auth Bedrock-calling surface — do NOT widen to
# 0.0.0.0/0 in prod.
resource "aws_security_group" "ml" {
  name   = "${var.project}-app-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.ingress_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-app-sg" }
}

# Runtime task role — the container uses THIS to authenticate boto3 calls to
# Bedrock + write lineage. (The execution role only covers ECS pull/logs.)
resource "aws_iam_role" "task" {
  name = "${var.project}-task"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "task" {
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"], Resource = ["arn:aws:bedrock:*:*:inference-profile/*", "arn:aws:bedrock:${var.region}::foundation-model/*"] },
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.ml_lineage.arn}/*" }
    ]
  })
}

resource "aws_ecs_task_definition" "ml" {
  family                   = "${var.project}-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512  # 0.5 vCPU
  memory                   = 1024 # 1 GB
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.task.arn
  # Image is built on Apple Silicon (linux/arm64); Fargate defaults to x86_64,
  # so pin the task to ARM64 or the container dies with "exec format error".
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }
  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}:latest"
    essential = true
    environment = [
      { name = "AWS_REGION", value = var.region },
      { name = "BEDROCK_MODEL_ID", value = var.bedrock_model_id },
      { name = "LINEAGE_BUCKET", value = aws_s3_bucket.ml_lineage.id }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ml.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "ml" {
  name            = "${var.project}-svc"
  cluster         = aws_ecs_cluster.ml.id
  task_definition = aws_ecs_task_definition.ml.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  depends_on      = [aws_iam_service_linked_role.ecs]
  network_configuration {
    subnets          = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    security_groups  = [aws_security_group.ml.id]
    assign_public_ip = true # public subnets, no NAT
  }
}

# ---------------------------------------------------------------------------
# Lambda + Function URL — FREE-TIER API ingress (Lambda's 1st million reqs/mo
# are free). Why not API Gateway: it bills ~$3.50/M req. Enterprise: API Gateway.
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "health" {
  function_name    = "${var.project}-health"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  memory_size      = 128
  timeout          = 10
  filename         = "${path.module}/handler.zip"
  source_code_hash = filebase64sha256("${path.module}/handler.py")
}
resource "aws_lambda_function_url" "health" {
  function_name      = aws_lambda_function.health.function_name
  authorization_type = "NONE"
}
# Public invocation is denied without this — aws_lambda_function_url alone
# doesn't add a resource policy, so the URL returned 403. This allows it.
resource "aws_lambda_permission" "url" {
  function_name          = aws_lambda_function.health.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}
resource "aws_iam_role" "lambda" {
  name = "${var.project}-lambda"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ---------------------------------------------------------------------------
# SSM Parameter Store — config + secrets (free tier). Enterprise: Secrets
# Manager + rotation + KMS, injected at runtime via task execution role.
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "bedrock_model_id" {
  name  = "/${var.project}/bedrock-model-id"
  type  = "String"
  value = var.bedrock_model_id
}

# ---------------------------------------------------------------------------
# CloudWatch — budget alarm so nothing quietly bills. Set day one.
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  budget_type       = "COST"
  limit_amount      = "5.00"
  limit_unit        = "USD"
  time_period_start = var.budget_start
  time_unit         = "MONTHLY"
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.notify_email]
  }
}

# ---------------------------------------------------------------------------
# Observability — Bedrock model invocation logging (per-call model/tokens/
# latency/errors) to CloudWatch + S3, and a latency alarm. This is the
# "dull, recoverable" layer: alert on latency, not just downtime.
# (drift vs breakage vs decay separation is a design doc, not IaC yet.)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "bedrock_logging" {
  name = "${var.project}-bedrock-logging"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "bedrock.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "bedrock_logging" {
  role = aws_iam_role.bedrock_logging.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:PutLogEvents", "logs:CreateLogStream", "logs:DescribeLogGroups", "logs:PutRetentionPolicy"], Resource = "${aws_cloudwatch_log_group.ml.arn}:*" },
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.ml_lineage.arn}/*" }
    ]
  })
}

resource "aws_bedrock_model_invocation_logging_configuration" "ml" {
  depends_on = [aws_iam_role_policy.bedrock_logging]
  logging_config {
    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.ml.name
      role_arn       = aws_iam_role.bedrock_logging.arn
    }
    s3_config {
      bucket_name = aws_s3_bucket.ml_lineage.id
      key_prefix  = "bedrock-invocation-logs/"
    }
  }
}

# ponytail: single latency alarm; add InvocationErrorRate/Throttling alarms if
# the metric is present in-region, and the cost alarm is the budget above.
resource "aws_cloudwatch_metric_alarm" "bedrock_latency" {
  alarm_name          = "${var.project}-bedrock-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "InvocationLatency"
  namespace           = "AWS/Bedrock"
  period              = 300
  statistic           = "Average"
  threshold           = 5000
  alarm_description   = "Bedrock invocation latency above 5s average"
}
