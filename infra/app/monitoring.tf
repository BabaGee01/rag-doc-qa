# Operational alarms go to the same on-call topic as security findings.
locals {
  alb_dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy" {
  alarm_name          = "${var.project}-no-healthy-tasks"
  alarm_description   = "No healthy targets behind the load balancer - the site is down"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  dimensions          = local.alb_dimensions
  alarm_actions       = [data.aws_sns_topic.security_alerts.arn]
  ok_actions          = [data.aws_sns_topic.security_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "errors_5xx" {
  alarm_name          = "${var.project}-5xx"
  alarm_description   = "App is returning server errors"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = local.alb_dimensions
  alarm_actions       = [data.aws_sns_topic.security_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "${var.project}-memory-high"
  alarm_description   = "Task memory above 85% - uploads may cause out-of-memory restarts"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { ClusterName = aws_ecs_cluster.main.name, ServiceName = aws_ecs_service.app.name }
  alarm_actions       = [data.aws_sns_topic.security_alerts.arn]
}

# Single pane of glass for security operations: edge, threats, compliance and service health.
resource "aws_cloudwatch_dashboard" "security_ops" {
  dashboard_name = "${var.project}-security-operations"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 2
        properties = {
          markdown = "## ${var.project} - Security Operations\nEdge (WAF) · Threat detection (GuardDuty) · Compliance & vulnerabilities (Security Hub, Inspector) · CIS audit alarms · Service health. Runbook: `docs/INCIDENT_RESPONSE.md`"
        }
      },
      {
        type = "metric", x = 0, y = 2, width = 12, height = 6
        properties = {
          title  = "WAF: allowed vs blocked requests"
          region = "us-east-1"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/WAFV2", "AllowedRequests", "WebACL", var.project, "Rule", "ALL"],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.project, "Rule", "ALL"],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 2, width = 12, height = 6
        properties = {
          title  = "WAF: blocks by rule"
          region = "us-east-1"
          stat   = "Sum"
          period = 300
          metrics = [for r in ["rate-limit-ask", "rate-limit-global", "AWSManagedRulesAmazonIpReputationList", "AWSManagedRulesKnownBadInputsRuleSet", "AWSManagedRulesCommonRuleSet"] :
          ["AWS/WAFV2", "BlockedRequests", "WebACL", var.project, "Rule", r]]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 12, height = 6
        properties = {
          title  = "Security findings (GuardDuty / Security Hub / Inspector)"
          region = var.aws_region
          stat   = "Sum"
          period = 3600
          metrics = [for m in ["GuardDutyHighFindings", "GuardDutyFindings", "SecurityHubCritical", "SecurityHubHigh", "InspectorVulnerability"] :
          ["SecurityFindings", m]]
        }
      },
      {
        type = "metric", x = 12, y = 8, width = 12, height = 6
        properties = {
          title  = "CIS audit events (CloudTrail)"
          region = var.aws_region
          stat   = "Sum"
          period = 3600
          metrics = [for m in ["root-account-usage", "unauthorized-api-calls", "console-signin-without-mfa", "console-signin-failures", "iam-policy-changes", "security-group-changes"] :
          ["CISBenchmark", m]]
        }
      },
      {
        type = "log", x = 0, y = 14, width = 12, height = 6
        properties = {
          title  = "Top blocked client IPs (WAF logs)"
          region = "us-east-1"
          query  = "SOURCE '${aws_cloudwatch_log_group.waf.name}' | fields httpRequest.clientIp as ip, terminatingRuleId as rule | filter action = 'BLOCK' | stats count(*) as blocked by ip, rule | sort blocked desc | limit 10"
          view   = "table"
        }
      },
      {
        type = "metric", x = 12, y = 14, width = 12, height = 6
        properties = {
          title  = "Service health"
          region = var.aws_region
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "p95", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 20, width = 24, height = 5
        properties = {
          title  = "ECS CPU / memory (%)"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", var.project],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", var.project],
          ]
        }
      },
    ]
  })
}
