# Automated containment: a high-severity GuardDuty Runtime Monitoring finding on one of this
# service's tasks triggers a Lambda that captures forensic metadata, tags and stops the task.
# ECS replaces it with a clean task from the trusted image; humans follow docs/INCIDENT_RESPONSE.md.

data "archive_file" "contain_task" {
  type        = "zip"
  source_file = "${path.module}/lambda/contain_ecs_task.py"
  output_path = "${path.module}/.build/contain_ecs_task.zip"
}

resource "aws_cloudwatch_log_group" "contain_task" {
  name              = "/aws/lambda/${var.project}-contain-ecs-task"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.app.arn
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

resource "aws_iam_role" "contain_task" {
  name               = "${var.project}-contain-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "contain_task" {
  role = aws_iam_role.contain_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["ecs:DescribeTasks", "ecs:StopTask", "ecs:TagResource"]
        Resource  = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task/${aws_ecs_cluster.main.name}/*"
        Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.main.arn } }
      },
      { Effect = "Allow", Action = "sns:Publish", Resource = data.aws_sns_topic.security_alerts.arn },
      { Effect = "Allow", Action = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = data.aws_kms_alias.security.target_key_arn },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.contain_task.arn}:*"
      },
    ]
  })
}

resource "aws_lambda_function" "contain_task" {
  function_name    = "${var.project}-contain-ecs-task"
  role             = aws_iam_role.contain_task.arn
  runtime          = "python3.13"
  handler          = "contain_ecs_task.handler"
  filename         = data.archive_file.contain_task.output_path
  source_code_hash = data.archive_file.contain_task.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      CLUSTER_NAME = aws_ecs_cluster.main.name
      TOPIC_ARN    = data.aws_sns_topic.security_alerts.arn
      DRY_RUN      = var.auto_containment_enabled ? "false" : "true"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.contain_task.name
  }

  tracing_config {
    mode = "Active"
  }
}

resource "aws_cloudwatch_event_rule" "runtime_threat" {
  name        = "${var.project}-runtime-threat"
  description = "High-severity GuardDuty findings on ${var.project} ECS tasks"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
      resource = {
        resourceType      = ["ECSCluster"]
        ecsClusterDetails = { name = [aws_ecs_cluster.main.name] }
      }
    }
  })
}

resource "aws_sqs_queue" "containment_dlq" {
  name                      = "${var.project}-containment-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate
  kms_master_key_id         = aws_kms_key.app.arn
}

resource "aws_sqs_queue_policy" "containment_dlq" {
  queue_url = aws_sqs_queue.containment_dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.containment_dlq.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.runtime_threat.arn } }
    }]
  })
}

resource "aws_cloudwatch_event_target" "runtime_threat" {
  rule = aws_cloudwatch_event_rule.runtime_threat.name
  arn  = aws_lambda_function.contain_task.arn

  retry_policy {
    maximum_retry_attempts       = 4
    maximum_event_age_in_seconds = 3600
  }

  dead_letter_config {
    arn = aws_sqs_queue.containment_dlq.arn
  }
}

# Any message here means an automated containment did not run - page a human.
resource "aws_cloudwatch_metric_alarm" "containment_failed" {
  alarm_name          = "${var.project}-containment-failed"
  alarm_description   = "Automated ECS containment failed; follow docs/INCIDENT_RESPONSE.md manually"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.containment_dlq.name }
  alarm_actions       = [data.aws_sns_topic.security_alerts.arn]
}

resource "aws_lambda_permission" "runtime_threat" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.contain_task.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.runtime_threat.arn
}
