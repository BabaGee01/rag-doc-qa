output "security_alerts_topic_arn" {
  value = aws_sns_topic.security_alerts.arn
}

output "cloudtrail_bucket" {
  value = aws_s3_bucket.cloudtrail.bucket
}

output "guardduty_detector_id" {
  value = aws_guardduty_detector.this.id
}

output "security_report_function" {
  value = aws_lambda_function.security_report.function_name
}
