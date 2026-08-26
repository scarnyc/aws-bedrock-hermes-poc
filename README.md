# AWS ML / IaaS Platform — portfolio project

Prep target: **Principal Machine Learning Engineer @ Accelerant** (risk exchange).
Goal: own how ML + AI run in production — data/feature pipelines, training, inference,
deployment, monitoring, and the infra behind agentic AI. Build a credible, working
portfolio stack on **AWS** with a **locally-served model API** clients can plug into.

## What this is

Two tiers, one **OpenAI-compatible `/v1` contract** so clients don't change between them:

```
CLIENTS (Hermes / OpenCode / any OpenAI SDK / unsloth models / A2A agents)
              │  HTTP  /v1/chat/completions
              ▼
  ┌───────────────────────────────┬──────────────────────────────────────────┐
  │  LOCAL (dev — this box)       │  AWS (prod — IaC)                        │
  │  llama-server (Metal)         │  vLLM / llama.cpp + DSpark               │
  │  Qwen3.6-35B-A3B (fits 64GB)  │  DeepSeek-V4-Flash 284B (103GB+ / GPU)   │
  │  127.0.0.1:8000               │  EKS/EC2 GPU node + ECR + ALB            │
  └───────────────────────────────┴──────────────────────────────────────────┘
              │  same response shape
              ▼
        feature store, registry + lineage, monitoring (drift/breakage/decay)
```

Why the split: DeepSeek-V4-Flash is **284B total / 13B active** MoE with a ~103GB
memory floor — it physically cannot run on a 64GB box. Local dev uses a model that
fits (proven: Qwen3.6-35B-A3B). The 284B model runs behind vLLM/DSpark on AWS
hardware (GPU / Inferentia). Identical OpenAI-compatible contract = one client.

## Status

- [x] Local OpenAI-compatible serving API proven (llama-server, Qwen3.6-35B-A3B).
- [ ] AWS IaC stack (Terraform: VPC + EKS/EC2 GPU + S3 + ECR + serving deployment + monitoring).
- [ ] Model registry / lineage + governance/audit story (regulatory angle — Accelerant is insurance).
- [ ] Monitoring: data drift vs pipeline breakage vs performance decay; slow-label handling.
- [ ] Agentic serving: orchestration, retrieval, caching, cost + latency control; A2A route.

## Running the local API

```bash
scripts/serve-local.sh                      # defaults in this file
curl -s http://127.0.0.1:8000/v1/models
curl -s http://127.0.0.1:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-35b-a3b","messages":[{"role":"user","content":"Say hi in 5 words"}],"max_tokens":64}'
# Stop: pkill -f llama-server   (frees ~24GB RAM)
```

## Hard constraints on this box (learned)

- **RAM:** 64GB. → 284B models are out; 35B-A3B (13B active) fits.
- **Runtime:** llama.cpp (Metal) works; **vLLM needs CUDA → won't run on Apple Silicon.**
- **AWS creds:** none configured (`~/.aws` absent) — needed before any `terraform apply`.
- **Terraform:** not installed (add via `brew install terraform`).

## Clients → the API

- **curl:** any `/v1/*` call works (proven).
- **Hermes:** point a profile at it as an OpenAI-compatible custom provider via
  `model.base_url` + `model.api_key` (see hermes-agent skill). Don't flip the live session.
- **unsloth / OpenAI SDK / A2A:** all consume the same `/v1` shape — A2A adds an
  agent-card + task discovery layer on top, which is the next slice.

## Secrets

AWS credentials belong in **envchain** (like `hermes-aws`), never in the repo or memory.
