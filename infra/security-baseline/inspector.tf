# Amazon Inspector: continuous CVE scanning of ECR images (on push and when new CVEs are published),
# plus EC2 and Lambda. Replaces ECR basic scanning with enhanced scanning account-wide.
resource "aws_inspector2_enabler" "this" {
  account_ids    = [local.account_id]
  resource_types = ["ECR", "EC2", "LAMBDA"]
}
