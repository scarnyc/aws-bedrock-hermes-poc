# Contributing

Contributions are welcome. This is a small, focused portfolio project — keep changes
tight and aligned with the existing shape.

## Ground rules

- **Bedrock-only.** No local model server. Everything lives on AWS; Amazon Bedrock is
  the sole model provider.
- **One `/v1` contract.** Any client change must preserve the OpenAI-compatible
  `/v1/chat/completions` + `/v1/models` shape.
- **Free-tier safe by default.** The `infra/terraform/free-tier/` module must not pull in
  paid-by-default services (NAT, ALB, Secrets Manager, CloudTrail, API Gateway). Enterprise
  variants go in `infra/terraform/enterprise-reference.tf` as commented reference.

## Working on the Terraform

Terraform 1.15.x is expected. The free-tier checks are:

```bash
terraform fmt -check infra/terraform/free-tier/
terraform validate infra/terraform/free-tier/
```

`terraform plan`/`apply` need live AWS credentials — never commit those.

## Rebuilding the Lambda artifact

The Lambda function is a single Python file. Rebuild the zip after changing `handler.py`:

```bash
zip -j infra/terraform/free-tier/handler.zip infra/terraform/free-tier/handler.py
```

`handler.zip`, `.terraform/`, `*.tfstate*`, and `tfplan` are gitignored.

## Commit style

Conventional commits (`type(scope): subject`), matching the existing history:

```
feat(deploy): ...
fix(deploy): ...
docs(deploy): ...
```

## Reporting bugs / opening PRs

Describe the behavior, the expected result, and the minimal reproduction. Keep PRs small
and focused on one concern.
