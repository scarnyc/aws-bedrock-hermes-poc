---
title: Deploying the Fargate /v1→Bedrock proxy (free-tier gotcha chain)
category: runtime-errors
module: infra/terraform/free-tier
tags: [aws, bedrock, fargate, ecs, terraform, deploy, iam]
problem_type: runtime-errors
track: bug
date: 2026-08-27
---

# Deploying the Fargate /v1→Bedrock proxy (free-tier gotcha chain)

## Problem

Get the OpenAI-compatible `/v1`→Bedrock proxy (ECS Fargate, free-tier module) to
`terraform apply` cleanly and run the container, on an account where the deploy
user starts with a narrow IAM policy.

## Symptoms

Applied sequentially, each fix surfaced the next 4xx/403:
- `terraform plan`/`apply` 403s on different IAM actions each run.
- `s3:PutObjectLockConfiguration` → `409 InvalidBucketState: Versioning must be 'Enabled'`.
- Bedrock `PutModelInvocationLoggingConfiguration` → `400 ... Failed to validate permissions
  for log group ... Verify the IAM role permissions are correct.`
- ECS `CreateService` → `400 Unable to assume the service linked role`.
- ECR pull → `403 ... not authorized to perform: ecr:GetDownloadUrlForLayer`.
- Container `exec /usr/local/bin/uvicorn: exec format error`.

## What Didn't Work

- Hand-scoping the deploy-user policy per-action. The AWS provider surfaces read
  (Describe/Tag) AND apply-time (Modify/Put/List) actions only when it actually
  calls them, so the list is unbounded and each apply reveals another.
- Fixing only the action name in the Bedrock logging role (`cloudwatch:PutLogEvents`
  → `logs:PutLogEvents`) — the validation failure was actually the resource scope.
- Building the image with `--platform linux/amd64` on Apple Silicon — hit a
  buildx cache conflict for the wrong-platform base image.

## Solution

1. **Deploy-user IAM:** attach AWS-managed `AdministratorAccess` for bootstrap
   (one click, no paste, ends the whack-a-mole). Runtime roles stay least-privilege.
2. **S3 object-lock** needs versioning first:
   `depends_on = [aws_s3_bucket_versioning.ml_lineage]`.
3. **Bedrock logging role** — pass the role ARN and scope the logs Resource with
   the trailing wildcard: `role_arn = aws_iam_role.bedrock_logging.arn`,
   `Resource = "${aws_cloudwatch_log_group.ml.arn}:*"` (the log group ARN has no `:*`),
   and use `logs:PutLogEvents` (not `cloudwatch:PutLogEvents`).
4. **ECS service-linked role** — create `aws_iam_service_linked_role.ecs`
   (`aws_service_name = "ecs.amazonaws.com"`) and `depends_on` it from the service.
5. **ECR pull** — add `ecr:GetDownloadUrlForLayer` to the execution role (it had
   only `GetAuthorizationToken`/`BatchGetImage`).
6. **ARM64 image** — the image is built on Apple Silicon (linux/arm64), but Fargate
   defaults to x86_64. Pin the task:
   `runtime_platform { operating_system_family = "LINUX"; cpu_architecture = "ARM64" }`.

## Why This Works

Each was a distinct resource-behavior/vendor contract. The Fargate platform mismatch
(`exec format error`), the ECS service-linked-role prerequisite, the ECR
layer-download permission, and the CloudWatch log-group ARN lacking `:*` are all
specific constraints a grep through an earlier doc/plan wouldn't surface — only
living `apply` output reveals them.

## Prevention

- Bootstrap any Terraform deploy user with `AdministratorAccess`, then tighten the
  policy to the module's resource families once the stack is live.
- For ECS on Fargate, always pin `runtime_platform` to the image arch and remember
  the service-linked role + `ecr:GetDownloadUrlForLayer`.
- When a Bedrock/CloudWatch role fails validation, check the Resource ARN (`:*`
  suffix) before the action names.
- Test the image's arch with `docker buildx imagetools inspect <image>` before
  wiring it to Fargate.
