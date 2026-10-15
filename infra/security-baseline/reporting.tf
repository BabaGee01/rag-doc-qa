# Weekly security posture report: compliance score, open findings by severity and the top failing
# controls, emailed every Monday 08:00 UK time.

data "archive_file" "security_report" {
  type        = "zip"
  source_file = "${path.module}/lambda/security_report.py"
  output_path = "${path.module}/.build/security_report.zip"
}

resource "aws_cloudwatch_log_group" "security_report" {
  name              = "/aws/lambda/security-posture-report"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.security.arn
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "security_report" {
  name               = "security-posture-report"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "security_report" {
  role = aws_iam_role.security_report.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["securityhub:GetFindings"]
        Resource = "arn:${local.partition}:securityhub:${var.aws_region}:${local.account_id}:hub/default"
      },
      { Effect = "Allow", Action = ["sns:Publish"], Resource = aws_sns_topic.security_alerts.arn },
      { Effect = "Allow", Action = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = aws_kms_key.security.arn },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.security_report.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "security_report" {
  function_name    = "security-posture-report"
  role             = aws_iam_role.security_report.arn
  runtime          = "python3.13"
  handler          = "security_report.handler"
  filename         = data.archive_file.security_report.output_path
  source_code_hash = data.archive_file.security_report.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = { TOPIC_ARN = aws_sns_topic.security_alerts.arn }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.security_report.name
  }

  tracing_config {
    mode = "Active"
  }
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "security-report-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.security_report.arn }]
  })
}

resource "aws_scheduler_schedule" "weekly_report" {
  name                         = "weekly-security-posture-report"
  schedule_expression          = "cron(0 8 ? * MON *)"
  schedule_expression_timezone = "Europe/London"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.security_report.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
