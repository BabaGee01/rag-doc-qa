# Detection -> notification pipeline.
#   GuardDuty / Security Hub / Inspector -> EventBridge -> SNS (email, KMS-encrypted)
#                                                     \-> CloudWatch Logs (searchable history + metrics)

resource "aws_sns_topic" "security_alerts" {
  name              = "security-alerts"
  kms_master_key_id = aws_kms_key.security.id
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAwsPublishers"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "cloudwatch.amazonaws.com", "budgets.amazonaws.com"] }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.security_alerts.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- High-severity GuardDuty findings (7.0+) -> email ---
resource "aws_cloudwatch_event_rule" "guardduty_high" {
  name        = "guardduty-high-severity"
  description = "GuardDuty findings with severity >= 7 (High/Critical)"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 7] }] }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_high_sns" {
  rule = aws_cloudwatch_event_rule.guardduty_high.name
  arn  = aws_sns_topic.security_alerts.arn
  input_transformer {
    input_paths = {
      severity = "$.detail.severity"
      type     = "$.detail.type"
      title    = "$.detail.title"
      resource = "$.detail.resource.resourceType"
      region   = "$.region"
      id       = "$.detail.id"
    }
    input_template = "\"[GuardDuty severity <severity>] <title> | Type: <type> | Resource: <resource> | Triage: https://<region>.console.aws.amazon.com/guardduty/home?region=<region>#/findings?fId=<id> | Runbook: docs/INCIDENT_RESPONSE.md\""
  }
}

# --- Critical/High Security Hub findings (controls, Inspector CVEs, Access Analyzer) -> email ---
# GuardDuty is excluded here because it already alerts directly above.
resource "aws_cloudwatch_event_rule" "securityhub_high" {
  name        = "securityhub-critical-high"
  description = "New, active Critical/High findings in Security Hub"
  event_pattern = jsonencode({
    source        = ["aws.securityhub"]
    "detail-type" = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity    = { Label = ["CRITICAL", "HIGH"] }
        Workflow    = { Status = ["NEW"] }
        RecordState = ["ACTIVE"]
        ProductName = [{ "anything-but" = "GuardDuty" }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "securityhub_high_sns" {
  rule = aws_cloudwatch_event_rule.securityhub_high.name
  arn  = aws_sns_topic.security_alerts.arn
  input_transformer {
    input_paths = {
      severity = "$.detail.findings[0].Severity.Label"
      title    = "$.detail.findings[0].Title"
      product  = "$.detail.findings[0].ProductName"
      resource = "$.detail.findings[0].Resources[0].Id"
      region   = "$.region"
    }
    input_template = "\"[Security Hub <severity>] <title> | Source: <product> | Resource: <resource> | Triage, then set workflow to NOTIFIED/RESOLVED/SUPPRESSED: https://<region>.console.aws.amazon.com/securityhub/home?region=<region>#/findings\""
  }
}

# --- Searchable findings history + metrics for the security dashboard ---
resource "aws_cloudwatch_log_group" "findings" {
  name              = "/aws/events/security-findings"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.security.arn
}

resource "aws_cloudwatch_log_resource_policy" "events_to_logs" {
  policy_name = "eventbridge-security-findings"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"] }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.findings.arn}:*"
    }]
  })
}

resource "aws_cloudwatch_event_rule" "all_findings" {
  name        = "security-findings-to-logs"
  description = "All GuardDuty findings and active Medium+ Security Hub findings, for history and metrics"
  event_pattern = jsonencode({
    "$or" = [
      { source = ["aws.guardduty"], "detail-type" = ["GuardDuty Finding"] },
      {
        source        = ["aws.securityhub"]
        "detail-type" = ["Security Hub Findings - Imported"]
        detail = {
          findings = {
            Severity    = { Label = ["CRITICAL", "HIGH", "MEDIUM"] }
            RecordState = ["ACTIVE"]
            ProductName = [{ "anything-but" = "GuardDuty" }]
          }
        }
      },
    ]
  })
}

resource "aws_cloudwatch_event_target" "all_findings_logs" {
  rule       = aws_cloudwatch_event_rule.all_findings.name
  arn        = aws_cloudwatch_log_group.findings.arn
  depends_on = [aws_cloudwatch_log_resource_policy.events_to_logs]
}

locals {
  finding_metrics = {
    GuardDutyFindings      = "{ $.source = \"aws.guardduty\" }"
    GuardDutyHighFindings  = "{ $.source = \"aws.guardduty\" && $.detail.severity >= 7 }"
    SecurityHubCritical    = "{ $.source = \"aws.securityhub\" && $.detail.findings[0].Severity.Label = \"CRITICAL\" }"
    SecurityHubHigh        = "{ $.source = \"aws.securityhub\" && $.detail.findings[0].Severity.Label = \"HIGH\" }"
    SecurityHubMedium      = "{ $.source = \"aws.securityhub\" && $.detail.findings[0].Severity.Label = \"MEDIUM\" }"
    InspectorVulnerability = "{ $.source = \"aws.securityhub\" && $.detail.findings[0].ProductName = \"Inspector\" }"
  }
}

resource "aws_cloudwatch_log_metric_filter" "findings" {
  for_each       = local.finding_metrics
  name           = each.key
  log_group_name = aws_cloudwatch_log_group.findings.name
  pattern        = each.value
  metric_transformation {
    name          = each.key
    namespace     = "SecurityFindings"
    value         = "1"
    default_value = "0"
  }
}
