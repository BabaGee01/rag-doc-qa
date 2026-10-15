variable "project" {
  type    = string
  default = "rag-doc-qa"
}

variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

variable "alert_email" {
  description = "Receives security findings, CIS alarms, budget alerts and the weekly posture report."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly AWS spend threshold for budget alerts."
  type        = number
  default     = 120
}

variable "log_retention_days" {
  description = "Retention for security log groups (CIS / Security Hub CloudWatch.16 expects >= 365)."
  type        = number
  default     = 365
}

variable "cloudtrail_retention_days" {
  type    = number
  default = 365
}
