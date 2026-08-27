variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
variable "project" {
  description = "Resource name prefix"
  type        = string
  default     = "ml-accent"
}
variable "bedrock_model_id" {
  description = "Bedrock model to invoke. Use the cross-region inference-profile ID for Claude (bare aliases like anthropic.claude-opus-4-6 are NOT on-demand invocable; profile = us.anthropic.<model>). Requires the Anthropic use-case details form to be submitted (else 'Model use case details have not been submitted'). NVIDIA Nemotron runs on-demand with the bare ID. e.g. us.anthropic.claude-opus-4-6-v1"
  type        = string
  default     = "us.anthropic.claude-opus-4-6-v1"
}
variable "notify_email" {
  description = "Email for the $5 budget alarm. Required — supply your own (terraform.tfvars or -var)."
  type        = string
}
variable "budget_start" {
  description = "Budget start date (YYYY-MM-DD_HH:MM)"
  type        = string
  default     = "2026-09-01_00:00"
}
variable "ingress_cidr" {
  description = "CIDR allowed to reach the /v1 proxy on :8000. Required — supply your own (terraform.tfvars or -var). Tighten (or remove) after testing."
  type        = string
}
