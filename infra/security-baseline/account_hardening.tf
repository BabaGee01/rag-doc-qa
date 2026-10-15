# Account-wide guardrails flagged by CIS / AWS Foundational Security Best Practices.

resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
}

# Flags resources shared outside the account (S3, KMS, IAM roles, Lambda, SQS...). Free.
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "account-external-access"
  type          = "ACCOUNT"
}
