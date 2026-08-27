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
  description = "Bedrock model to invoke (e.g. deepseek.v3.2, anthropic.claude-...). Confirm with aws bedrock list-foundation-models"
  type        = string
  default     = "deepseek.v3.2"
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
