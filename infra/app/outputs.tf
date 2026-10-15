output "app_url" {
  value = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service" {
  value = aws_ecs_service.app.name
}

output "internal_alb_dns" {
  description = "Not reachable from the internet - only via CloudFront."
  value       = aws_lb.main.dns_name
}

output "security_dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.security_ops.dashboard_name}"
}

output "containment_function" {
  value = aws_lambda_function.contain_task.function_name
}

output "github_deploy_role_arn" {
  value = local.enable_github ? aws_iam_role.github_deploy[0].arn : null
}
