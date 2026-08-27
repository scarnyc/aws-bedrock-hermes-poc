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
  description = "Bedrock model to invoke. NVIDIA Nemotron runs on-demand with the bare model ID (unlike newer Claude models, which need a cross-region inference profile ID). e.g. nvidia.nemotron-super-3-120b"
  type        = string
  default     = "nvidia.nemotron-super-3-120b"
}
variable "notify_email" {
  description = "Email for the $5 budget alarm"
  type        = string
  default     = "info@aipmbydesign.com"
}
variable "budget_start" {
  description = "Budget start date (YYYY-MM-DD_HH:MM)"
  type        = string
  default     = "2026-09-01_00:00"
}
variable "ingress_cidr" {
  description = "CIDR allowed to reach the /v1 proxy on :8000. Tighten (or remove) after testing."
  type        = string
  default     = "70.19.106.72/32"
}
