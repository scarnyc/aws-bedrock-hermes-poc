#!/usr/bin/env bash
# Build + push the /v1->Bedrock proxy image to ECR.
# Usage: scripts/push.sh <aws-account-id>
# Prints the image URI so you can set ecr_image.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-ml-accent}"
ACCT="$1"
REPO="${ACCT}.dkr.ecr.${REGION}.amazonaws.com/${PROJECT}-app:latest"

docker build -t "$REPO" -f infra/container/Dockerfile infra/container
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCT}.dkr.ecr.${REGION}.amazonaws.com"
docker push "$REPO"
echo "ecr_image = $REPO"
