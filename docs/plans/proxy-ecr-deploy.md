---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
title: Build & deploy the /v1→Bedrock proxy (ECR + container)
created: 2026-08-26
feature: "aws-bedrock-hermes-poc: add ECR repo + FastAPI /v1→Bedrock proxy so the ECS service pulls a real image and terraform apply yields a healthy Fargate app serving /v1 behind the Lambda Function URL."
product_contract_source: session (user instruction)
product_contract_preservation: unchanged
---

# Build & deploy the /v1→Bedrock proxy

## Problem frame

The free-tier IaC validates and `terraform plan` is clean (23 resources), but the ECS task references a placeholder `ecr_image` (`000000000000.dkr.ecr…/ml-accent-app:latest`), so the Fargate service can't pull a real container and the platform is a skeleton with nothing flowing through it. Goal: add an ECR repo and a real FastAPI `/v1→Bedrock` proxy so the stack is deployable and `/v1/chat/completions` is live.

## Scope

In: ECR repository, proxy container (Dockerfile + application), build/push path, the two IAM deltas the proxy needs, wiring the real image into the module. Model = `nvidia.nemotron-super-3-120b` (a Bedrock foundation model, so the exec role must allow `bedrock:InvokeModel` on `foundation-model/*`, not just `inference-profile/*`).

Out: auth/rate-limiting, streaming (SSE), tool_calls, model-invocation-logging config, drift/breakage/decay monitoring — all deferred to the observability slice. No `apply` in this plan (execution verifies `plan`; `apply` is a separate user-gated step).

## Implementation units

### I1 — ECR repository (infra/terraform/free-tier/main.tf)
- Add `aws_ecr_repository` (`<var.project>-app`, image tags mutable), plus an `aws_ecr_repository_policy`/lifecycle not required for a POC (ponytail: single repo, no lifecycle policy until spend matters).
- `ecr_image` variable default stays a placeholder but is now overridable by the build script's output.

### I2 — Proxy container (infra/container/)
- **`app.py`** — FastAPI, port 8000 (matches task definition):
  - `GET /v1/models` → OpenAI list shape with `BEDROCK_MODEL_ID`.
  - `POST /v1/chat/completions` → translate OpenAI `messages` → boto3 `bedrock-runtime.converse` (`modelId=BEDROCK_MODEL_ID`, `system`/`user`/`assistant` content, `inferenceConfig.maxTokens/temperature`), map the Converse response → OpenAI `choices[].message` + `usage`.
  - **Lineage shadow:** on each call write `<LINEAGE_BUCKET>/<YYYY-MM-DD>/<uuid>.json` (model, prompt/completion tokens, latency_ms, request_id, timestamp, success) via `boto3 s3.put_object`; also `print()` a JSON log line (→ CloudWatch). Robust to lineage-write failure (log + continue, never fail the request).
  - Reads `BEDROCK_MODEL_ID`, `LINEAGE_BUCKET`, `AWS_REGION` from env.
- **`Dockerfile`** — `python:3.12-slim`, `pip install fastapi uvicorn boto3`, copy `app.py`, `CMD ["uvicorn","app:app","--host","0.0.0.0","--port","8000"]`, non-root, `--no-cache-dir`.

### I3 — Build/push path (scripts/push.sh)
- `docker build -t <acct>.dkr.ecr.<region>.amazonaws.com/<project>-app:latest .` then `aws ecr get-login-password | docker login …` + `docker push`. Prints the image URI so the caller sets `ecr_image`.

### I4 — IAM deltas (execution role, infra/terraform/free-tier/main.tf)
- `aws_iam_role_policy.ecs_execution`: add `s3:PutObject` (scoped to the lineage bucket ARN) and widen `bedrock:InvokeModel` Resource to also cover `arn:aws:bedrock:${var.region}::foundation-model/*` (currently inference-profile-only).

## Test scenarios

- **I1:** `terraform fmt -check` + `terraform validate` pass; `terraform plan` shows the new `aws_ecr_repository` (+ no error).
- **I2:** `app.py` self-check / small test: `/v1/models` returns the model id from env; `/v1/chat/completions` with a stub `boto3` client (monkeypatched `converse`) returns an OpenAI-shaped `choices[].message` + `usage`, and calls `s3.put_object` with a lineage payload.
- **I3:** `scripts/push.sh` shellcheck-clean (or `bash -n`); builds the image without a runtime error.
- **I4:** plan confirms the exec-role policy now includes `bedrock:InvokeModel` on `foundation-model/*` and `s3:PutObject`; no new plan errors.

## Decisions / rationale

- **Thin stateless proxy** (Converse, not InvokeModel) — stable boto3 API, handles Nemotron's foundation-model id; no hand-rolled request schema.
- **Converse over InvokeModel** for the translation seam; mapping OpenAI⇄Converse is the only non-trivial logic.
- **Lineage write is best-effort** (log + continue) so a storage hiccup never fails a user request.
- **ECR repo minimal** (no lifecycle/scan policies in a POC); add when spend/security posture matters.
- **No auth/streaming/tool_calls** yet — that's the agentic slice.

## Dependencies / sequencing

I1 + I4 (terraform) → `terraform plan` green. I2 + I3 → image builds/pushes. The ECS task definition already carries the env (`BEDROCK_MODEL_ID`, `LINEAGE_BUCKET`) and port 8000 — no change needed there beyond setting `ecr_image`.

## Verification (execution)

`terraform fmt -check` + `terraform validate` + `terraform plan` (no error, shows ECR repo); `bash -n scripts/push.sh`; a `python3` run of `app.py`'s self-check proving the /v1 translation + lineage path with a stubbed boto3 client.
