# AWS WAF on CloudFront: managed threat-intel and OWASP rule groups plus edge rate limiting.

locals {
  managed_rule_groups = [
    # name, priority, rules overridden to COUNT (observed, not blocked)
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 10, count_rules = [] },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20, count_rules = [] },
    # Document uploads legitimately exceed the 8 KB body-size rule, so it's observed rather than enforced.
    { name = "AWSManagedRulesCommonRuleSet", priority = 30, count_rules = ["SizeRestrictions_BODY"] },
    # Anonymous IPs (VPNs, Tor, hosting) are logged for tuning before deciding to block.
    { name = "AWSManagedRulesAnonymousIpList", priority = 40, count_rules = ["AnonymousIPList", "HostingProviderIPList"] },
  ]
}

resource "aws_wafv2_web_acl" "main" {
  provider    = aws.us_east_1
  name        = var.project
  description = "Edge protection for ${var.project}"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Edge rate limit on the expensive endpoint (each question costs an LLM call).
  rule {
    name     = "rate-limit-ask"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_ask_rate_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
        scope_down_statement {
          byte_match_statement {
            search_string         = "/api/ask"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-ask"
      sampled_requests_enabled   = true
    }
  }

  # General flood protection.
  rule {
    name     = "rate-limit-global"
    priority = 2
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = 1000
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-global"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups
    content {
      name     = rule.value.name
      priority = rule.value.priority
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name
          dynamic "rule_action_override" {
            for_each = rule.value.count_rules
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.project
    sampled_requests_enabled   = true
  }
}

# Full request logs (WAF log group names must start with aws-waf-logs-).
resource "aws_cloudwatch_log_group" "waf" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${var.project}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.waf_logs.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  provider                = aws.us_east_1
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Don't persist visitors' session identifiers in logs.
  redacted_fields {
    single_header {
      name = "x-session-id"
    }
  }
}
