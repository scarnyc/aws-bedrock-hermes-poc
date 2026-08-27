# Monitoring design — drift vs breakage vs decay

The ML-level observability layer. Three DIFFERENT signals, differently detected and acted
on — the whole discipline is not confusing them (don't re-train on a breakage, don't roll
back on a drift).

## The three signals

- **Drift** — the input data distribution changed vs a baseline (feature/input drift; PSI/KS
  per feature vs a reference window, or prediction-distribution drift). Slow + gradual.
  Detect: distribution checks on inputs/predictions. **Act: re-train / refresh.** Tune
  thresholds to catch it before it hurts.
- **Breakage** — the call or pipeline FAILS: 5xx, 400 schema, throttling, dead-letter,
  missing feature, null handling. Binary + loud. Detect: error-rate / 5xx / throttle alarms.
  **Act: alert + roll back / retry/backoff** (the "dull, recoverable" ops case).
- **Decay** — the pipeline runs fine but performance degrades: accuracy / task-success dips,
  latency creeps, cost-per-request rises. Silent. Detect: scheduled eval (holdout or
  LLM-as-judge) + online success/latency/cost trends. **Act: re-train / adjust.**

## Slow-label handling

Real labels arrive days/weeks late. Use a fast surrogate (online task-success, latency, cost)
in the interim; reconcile when ground truth lands. Never gate the monitoring on slow labels.

## Mapping to the IaC

- `aws_bedrock_model_invocation_logging_configuration` → per-call model / tokens / latency /
  errors to CloudWatch (JSON) + the S3 lineage bucket (the data source for all three).
- `aws_cloudwatch_metric_alarm.bedrock_latency` (InvocationLatency > 5s avg) + the $5 budget
  alarm (cost) → the breakage/cost layer. Add `InvocationErrorRate` / Throttling alarms when
  the metric is present in-region.
- Drift + decay need scheduled distribution/eval checks — the detection *logic*, not IaC;
  deferred to the registry/eval slice.
