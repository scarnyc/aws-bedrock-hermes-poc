# ===========================================================================
# ENTERPRISE REFERENCE — the resources the free-tier demo deliberately OMITS.
# NOT part of the free-tier module; do not `terraform apply` this file alone.
# This is the interview talking-point: "here's what Accelerant would actually
# run," and the deltas from the $0 demo. Every block is swapped in when budget
# opens up.
# ===========================================================================

# ---------------------------------------------------------------------------
# 1. API GATEWAY — the enterprise front door.
#    Free-tier used a Lambda Function URL (free). Enterprise replaces it with
#    API Gateway because you need auth, throttling, WAF, staging/canary,
#    versioning, private endpoints, and X-Ray tracing.
#    COST: bills ~$3.50/M requests + data. Auth via Cognito/IAM/OIDC.
# ---------------------------------------------------------------------------
/*
resource "aws_api_gateway_rest_api" "ml" {
  name = "${var.project}-api"
}
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.ml.id
  parent_id   = aws_api_gateway_rest_api.ml.root_resource_id
  path_part   = "{proxy+}"
}
# Private, authoritative routing: API Gateway -> private VPC link -> NLB -> ECS
resource "aws_api_gateway_vpc_link" "ml" { name = "${var.project}-vpc-link" }
resource "aws_api_gateway_method" "any" {
  rest_api_id   = aws_api_gateway_rest_api.ml.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"          # enterprise: "AWS_IAM" or Cognito/NONE+Lambda authorizer
}
# Stage-based canary: blue/green rollout for models
resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.prod.id
  rest_api_id   = aws_api_gateway_rest_api.ml.id
  stage_name    = "prod"
  canary_settings { percent_traffic = 0 }
}
resource "aws_wafv2_web_acl" "ml" {  # WAF on top of API Gateway
  name = "${var.project}-waf"
  scope = "REGIONAL"
  default_action { allow {} }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-waf"
    sampled_requests_enabled   = true
  }
}
*/

# ---------------------------------------------------------------------------
# 2. EKS — enterprise compute. Free-tier used ECS Fargate (serverless).
#    EKS gives you Kubernetes: HPA/Karpenter autoscaling, GPU node groups for
#    self-hosted models, service mesh (Envoy/App Mesh), spot for cost, and
#    blue/green + canary via Argo Rollouts / CodePipeline.
#    COST: EKS control plane ~$73/mo + nodes. This replaces Fargate.
# ---------------------------------------------------------------------------
/*
resource "aws_eks_cluster" "ml" {
  name = "${var.project}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  vpc_config {
    subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    endpoint_public_access = true
  }
  # EKS managed node groups (CPU) + a separate GPU node group for model serving
}
resource "aws_eks_node_group" "gpu" {
  cluster_name = aws_eks_cluster.ml.name
  node_group_name = "${var.project}-gpu"
  instance_types = ["g5.2xlarge"]     # GPU — NOT free; spot for cost
  scaling_config { desired_size = 1; min_size = 0; max_size = 2 }
  # taints/labels so only model-serving pods land on GPU nodes
}
# KServe / vLLM / Triton for model inference on the GPU node group
*/

# ---------------------------------------------------------------------------
# 3. SECRETS MANAGER — enterprise config/secrets. Free-tier used SSM Parameter
#    Store (free). Secrets Manager adds automatic rotation, KMS encryption, and
#    audit of access. Injected at runtime via the task/pod execution role.
#    COST: ~$0.40/secret/mo. The GPU/cloud/key for Bedrock lives here, not in code.
# ---------------------------------------------------------------------------
/*
resource "aws_secretsmanager_secret" "bedrock_key" {
  name = "${var.project}/bedrock-api-key"
}
resource "aws_secretsmanager_secret_version" "bedrock_key" {
  secret_id = aws_secretsmanager_secret.bedrock_key.id
  secret_string = var.bedrock_key   # from envchain-aws, never committed
}
*/

# ---------------------------------------------------------------------------
# 4. CLOUDTRAIL — governance/audit. Enterprise turns this ON (regulators and
#    internal risk committees require an audit trail). Free-tier left it off to
#    avoid the small bill. Object-level logging onto the S3 lineage bucket (or a
#    separate secure audit bucket) gives the "who did what when" record.
#    COST: ~$2.10 per 100K management events; the first management-events trail
#    on a new account is often free for a while. This is the FIRST enterprise
#    add-on, because the role's regulatory angle demands it.
# ---------------------------------------------------------------------------
/*
resource "aws_cloudtrail" "ml" {
  name = "${var.project}-audit"
  s3_bucket_name = aws_s3_bucket.ml_lineage.id
  include_global_service_events = true
  is_multi_region_trail = true
  event_selector {
    include_management_events = true
    read_write_type = "All"
  }
}
*/

# ---------------------------------------------------------------------------
# 5. NAT + PRIVATE SUBNETS + INTERFACE VPC ENDPOINTS — enterprise networking.
#    Free-tier used public subnets (no NAT). Enterprise uses private subnets so
#    workloads never expose a public IP, with a NAT gateway for egress and
#    private (interface) VPC endpoints to reach Bedrock/S3/etc. without going
#    over the internet. NAT bills ~$32/mo; interface endpoints bill per-hour.
#    This is the real "private, complaint" network posture.
# ---------------------------------------------------------------------------
/*
resource "aws_nat_gateway" "ml" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
}
resource "aws_vpc_endpoint" "s3" {         # gateway endpoint (free) for S3
  vpc_id = aws_vpc.main.id
  service_name = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
}
resource "aws_vpc_endpoint" "bedrock" {    # interface endpoint (bills) for Bedrock
  vpc_id = aws_vpc.main.id
  service_name = "com.amazonaws.${var.region}.bedrock-runtime"
  vpc_endpoint_type = "Interface"
}
*/
