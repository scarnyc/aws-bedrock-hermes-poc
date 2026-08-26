# aws-bedrock-hermes-poc — Bedrock-only ML platform (portfolio)

Prep target: **Principal Machine Learning Engineer @ Accelerant** (risk exchange).
Goal: own how ML + AI run in production — data/feature pipelines, training, inference,
deployment, monitoring, and the infra behind agentic AI. A credible, working portfolio
stack on AWS where **Amazon Bedrock is the model provider** and this repo adds the
dull, recoverable systems the role is measured on: lineage, monitoring, governance.

## What this is

One OpenAI-compatible `/v1` contract so clients plug straight into Bedrock, plus the
platform around it:

```
CLIENTS (Hermes / any OpenAI SDK / A2A agents)
      │  HTTP  /v1/chat/completions
      ▼
 Amazon Bedrock  (sole model provider — Claude / Nova / GPT-5.x / Llama / Mistral / DeepSeek-V3.2)
      │  Hermes native Bedrock provider (main + aux); same /v1 shape everywhere
      ▼
 feature store, model registry + lineage, monitoring (drift vs breakage vs decay)
```

Everything runs on AWS. **No local model server** — Bedrock is the provider, full stop.
Platform infra (IaC in this repo): VPC (public subnets, no NAT) + S3 Object-Lock lineage
bucket + ECS Fargate app + Lambda Function URL ingress + SSM Parameter Store + CloudWatch
+ a $5 budget alarm. Enterprise escalation (API Gateway, EKS, Secrets Manager, CloudTrail,
NAT/private subnets) is spelled out in `infra/terraform/enterprise-reference.tf`.

## Why Bedrock, not a self-hosted GPU

DeepSeek-V4-Flash is **284B total / 13B active** MoE with a ~103GB+ memory floor. AWS
free tier has **no GPU**; GPU hosts for it run **$8–25k/mo**. Bedrock is per-token from
the first call (~$15/mo at our volume) and needs zero GPU. Lazy-correct: Bedrock API for
daily work, self-host only as a short demo.

## Status

- [x] Architecture + IaC scaffold (Terraform: VPC + S3 + Fargate + Lambda + SSM + budget).
- [ ] AWS account + creds → `terraform plan`/`apply`.
- [ ] Bedrock invocation + Hermes-as-Bedrock-client smoke test (main + aux).
- [ ] Model registry / lineage + governance audit (regulatory angle — Accelerant is insurance).
- [ ] Monitoring: data drift vs pipeline breakage vs performance decay; slow-label handling.
- [ ] Agentic serving: orchestration, retrieval, caching, cost + latency control; A2A route.

## Clients → the API

- **Hermes:** native Bedrock provider — main **and** auxiliary routes (compression / vision
  / summarizer) both work on Bedrock (issue #11946 resolved). Use **IAM access keys**
  (envchain `hermes-aws`) — not Bearer-Token auth (#29309 open). Config:
  `model.provider: bedrock`, `bedrock.region: us-east-1`.
- **curl / any OpenAI SDK:** point at `/v1/*` on the deployed ingress; same contract.
- **A2A agents:** Hermes and Bedrock AgentCore both speak A2A for the agent-card layer.

## Secrets

AWS credentials belong in **envchain** (`hermes-aws`), never in the repo or memory.
