# AWS Config: resource inventory, configuration history and compliance rules.
# Security Hub's controls are evaluated through Config, so it must be recording.

resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

resource "aws_s3_bucket" "config" {
  bucket        = "aws-config-${local.account_id}-${var.aws_region}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 365
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "ConfigAclCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config.arn
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
      {
        Sid       = "ConfigWrite"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config.arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.config]
}

resource "aws_config_configuration_recorder" "this" {
  name     = "default"
  role_arn = aws_iam_service_linked_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true # IAM is global: record it in this one home region
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "default"
  s3_bucket_name = aws_s3_bucket.config.bucket

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

# Organisation policy rules owned by this team (Security Hub adds its own control rules on top).
# CloudFront rules exist only in us-east-1 (global service); CloudFront WAF/HTTPS settings are
# enforced in Terraform and checked by Checkov in CI instead (docs/SECURITY.md RA-07).
locals {
  config_rules = {
    root-account-mfa-enabled         = { source = "ROOT_ACCOUNT_MFA_ENABLED", params = null }
    iam-root-access-key-check        = { source = "IAM_ROOT_ACCESS_KEY_CHECK", params = null }
    iam-user-mfa-enabled             = { source = "IAM_USER_MFA_ENABLED", params = null }
    access-keys-rotated              = { source = "ACCESS_KEYS_ROTATED", params = { maxAccessKeyAge = "90" } }
    multi-region-cloudtrail-enabled  = { source = "MULTI_REGION_CLOUD_TRAIL_ENABLED", params = null }
    guardduty-enabled                = { source = "GUARDDUTY_ENABLED_CENTRALIZED", params = null }
    vpc-flow-logs-enabled            = { source = "VPC_FLOW_LOGS_ENABLED", params = null }
    restricted-ssh                   = { source = "INCOMING_SSH_DISABLED", params = null }
    s3-bucket-public-read-prohibited = { source = "S3_BUCKET_PUBLIC_READ_PROHIBITED", params = null }
    ecs-containers-readonly-access   = { source = "ECS_CONTAINERS_READONLY_ACCESS", params = null }
    ecs-containers-nonprivileged     = { source = "ECS_CONTAINERS_NONPRIVILEGED", params = null }
    ecr-tag-immutability-enabled     = { source = "ECR_PRIVATE_TAG_IMMUTABILITY_ENABLED", params = null }
    required-tags = {
      source = "REQUIRED_TAGS"
      params = { tag1Key = "Project", tag2Key = "ManagedBy" }
    }
  }
}

resource "aws_config_config_rule" "baseline" {
  for_each = local.config_rules
  name     = each.key

  source {
    owner             = "AWS"
    source_identifier = each.value.source
  }

  input_parameters = each.value.params == null ? null : jsonencode(each.value.params)

  dynamic "scope" {
    for_each = each.key == "required-tags" ? [1] : []
    content {
      compliance_resource_types = [
        "AWS::EC2::VPC", "AWS::EC2::Subnet", "AWS::ECS::Cluster", "AWS::ECS::Service",
        "AWS::ElasticLoadBalancingV2::LoadBalancer", "AWS::S3::Bucket", "AWS::KMS::Key", "AWS::ECR::Repository",
      ]
    }
  }

  depends_on = [aws_config_configuration_recorder_status.this]
}

# Automatic remediation via SSM Automation: drift is fixed within minutes, not at the next audit.
data "aws_iam_policy_document" "ssm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "remediation" {
  name               = "config-auto-remediation"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume.json
}

resource "aws_iam_role_policy" "remediation" {
  role = aws_iam_role.remediation.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeHasNoResourceLevelPermissions"
        Effect   = "Allow"
        Action   = ["ec2:DescribeSecurityGroups"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:RevokeSecurityGroupIngress"]
        Resource = "arn:${local.partition}:ec2:*:${local.account_id}:security-group/*"
      },
      {
        Effect    = "Allow"
        Action    = ["s3:GetBucketPublicAccessBlock", "s3:PutBucketPublicAccessBlock"]
        Resource  = "arn:${local.partition}:s3:::*"
        Condition = { StringEquals = { "aws:ResourceAccount" = local.account_id } }
      },
    ]
  })
}

resource "aws_config_remediation_configuration" "restricted_ssh" {
  config_rule_name           = aws_config_config_rule.baseline["restricted-ssh"].name
  target_type                = "SSM_DOCUMENT"
  target_id                  = "AWS-DisablePublicAccessForSecurityGroup"
  automatic                  = true
  maximum_automatic_attempts = 3
  retry_attempt_seconds      = 60

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.remediation.arn
  }
  parameter {
    name           = "GroupId"
    resource_value = "RESOURCE_ID"
  }
}

resource "aws_config_remediation_configuration" "s3_public_read" {
  config_rule_name           = aws_config_config_rule.baseline["s3-bucket-public-read-prohibited"].name
  target_type                = "SSM_DOCUMENT"
  target_id                  = "AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock"
  automatic                  = true
  maximum_automatic_attempts = 3
  retry_attempt_seconds      = 60

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.remediation.arn
  }
  parameter {
    name           = "BucketName"
    resource_value = "RESOURCE_ID"
  }
}
