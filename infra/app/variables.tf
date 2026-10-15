variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "rag-doc-qa"
}

variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

variable "image_tag" {
  description = "Immutable image tag to deploy (set by `make deploy`; CI deploys by commit SHA afterwards)."
  type        = string
}

variable "anthropic_api_key_parameter" {
  description = "SSM SecureString holding the Anthropic API key (created by `make secret`, never in Terraform state)."
  type        = string
  default     = "/rag-doc-qa/anthropic-api-key"
}

variable "desired_count" {
  description = "Number of tasks. Sessions are in memory, so >1 relies on load balancer stickiness."
  type        = number
  default     = 1
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "use_fargate_spot" {
  description = "Run on Fargate Spot (~70% cheaper; tasks can be interrupted with 2 minutes' notice)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "waf_ask_rate_limit" {
  description = "Max /api/ask requests per client IP per 5 minutes, enforced at the edge."
  type        = number
  default     = 50
}

variable "auto_containment_enabled" {
  description = "Stop ECS tasks automatically on high-severity GuardDuty runtime findings. false = alert and log only (dry run)."
  type        = bool
  default     = true
}

variable "github_repository" {
  description = "Optional GitHub repo (owner/name) allowed to deploy via OIDC from the main branch."
  type        = string
  default     = ""
}

variable "create_github_oidc_provider" {
  description = "Set false if the GitHub OIDC provider already exists in this AWS account."
  type        = bool
  default     = true
}

variable "app_environment" {
  description = "Extra environment variables for the container."
  type        = map(string)
  default = {
    CLAUDE_MODEL          = "claude-opus-5"
    CLAUDE_EFFORT         = "medium"
    RATE_LIMIT_PER_MINUTE = "8"
    DAILY_QUESTION_CAP    = "300"
  }
}
