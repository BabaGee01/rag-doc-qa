# Threat Model (STRIDE)

**Assets:** the Anthropic API key (direct financial exposure), visitors' uploaded documents, the AWS account,
service availability, and the integrity of answers.

**Trust boundaries:** internet → CloudFront/WAF → private VPC → ECS task → Anthropic API; GitHub Actions → AWS.

| # | Threat | STRIDE | Mitigations | Residual risk |
|---|---|---|---|---|
| T1 | Attacker floods `/api/ask` to burn API credit | Denial of service (financial) | WAF rate limit per IP at the edge; app per-IP limit; global daily cap; budget alerts | Low: a distributed attack can still exhaust the daily cap, but not exceed it |
| T2 | API key stolen from code, image, logs or Terraform state | Information disclosure | Key only in an SSM SecureString created outside Terraform, injected at runtime; gitleaks in CI; no ECS Exec | Low |
| T3 | Visitor reads another visitor's uploads | Information disclosure | Per-session in-memory index keyed by a random UUID; 1-hour expiry; nothing persisted | Low: session IDs are bearer tokens, so anyone holding one can read that session |
| T4 | Prompt injection inside an uploaded document | Tampering | System prompt treats document content as data; answers must cite sources; the model has no tools or AWS access | Low: a user can only affect their own session's answers |
| T5 | Malicious upload exploits the PDF parser | Elevation of privilege | Type and size limits; pypdf kept current by Dependabot and pip-audit; read-only, non-root, no-capability container; task role has no AWS permissions; GuardDuty runtime monitoring with automatic containment | Low |
| T6 | Direct access bypassing WAF | Spoofing / tampering | ALB is internal; SG accepts only the CloudFront origin-facing prefix list | Very low |
| T7 | Spoofed client IP to evade rate limits | Spoofing | IP taken from `CloudFront-Viewer-Address`, which CloudFront sets itself | Very low |
| T8 | Compromised dependency or base image | Tampering | Pinned versions, Dependabot, Trivy gate, Inspector continuous rescanning, immutable ECR tags, SBOM and provenance | Medium: an undisclosed malicious package would not be caught by CVE scanning; runtime monitoring is the backstop |
| T9 | Compromised CI pipeline deploys malicious code | Elevation of privilege | OIDC role limited to `main`, one ECR repo and one ECS service; `iam:PassRole` limited to two roles for ECS; deploy needs a passing CI run; GitHub `production` environment can require approval | Medium: protect `main` with required reviews |
| T10 | Logs or audit trail tampered with to hide activity | Repudiation | CloudTrail log-file validation; KMS encryption; versioned bucket; alarm on any CloudTrail configuration change | Low: add S3 Object Lock in production (RA-03) |
| T11 | Admin credential theft leads to account takeover | Elevation of privilege | Root MFA; Config MFA/key-rotation rules; CIS alarms on root use and MFA-less sign-in; GuardDuty IAM anomaly detection | Medium until the IAM user moves to Identity Center (see SECURITY.md §4) |
