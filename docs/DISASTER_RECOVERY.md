# Resilience and Disaster Recovery

## Objectives

| | Target | How |
|---|---|---|
| **RTO** (time to restore service) | 30 minutes for a full region or account rebuild; under 2 minutes for task failure | Infrastructure as Code; ECS self-healing |
| **RPO** (acceptable data loss) | Zero for platform configuration; uploads are deliberately ephemeral | Everything lives in Git and versioned, encrypted Terraform state |

The app is **stateless by design**: uploaded documents live in memory for up to an hour, and nothing user-generated
is persisted. That's both a privacy control and what makes recovery simple.

## Failure scenarios

| Scenario | Automatic response | Manual action |
|---|---|---|
| Task crashes or fails health checks | ECS replaces it; the ALB stops routing to it | None |
| Bad deployment | Deployment circuit breaker rolls back to the last healthy task definition | Fix forward via a PR |
| Fargate Spot interruption | 2-minute warning; ECS starts a replacement | For guaranteed capacity, set `use_fargate_spot = false` |
| Availability Zone outage | ALB and subnets span two AZs; replacement tasks start in the healthy AZ | Production: run one NAT gateway per AZ (single NAT is a documented cost trade-off) |
| Compromised task | Containment Lambda stops it; ECS replaces it from the trusted image | [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md) |
| Region outage | None in the demo | Redeploy to another region: `make deploy AWS_REGION=eu-west-1` (see below) |
| Terraform state lost or corrupted | Versioned S3 bucket (90 days of history) | Restore the previous object version |
| Anthropic API outage | App returns a clear error; static UI stays up | Wait it out, or switch `CLAUDE_MODEL` to Claude on Amazon Bedrock |

## Region rebuild procedure

1. Create the key in the new region: `make secret AWS_REGION=eu-west-1`.
2. Run `make deploy AWS_REGION=eu-west-1`. This creates the state bucket, baseline and app from scratch.
3. Update DNS or share the new CloudFront URL. Images are rebuilt from the same commit, so the code is identical.

## Testing

"Demo mode" exercises this constantly: the whole environment is destroyed (`make destroy`) and rebuilt
(`make deploy`) between demos. The measured rebuild time is recorded below. A recovery plan that's never
tested is only a hope.

| Date | Exercise | Result |
|---|---|---|
| 2026-10-16 | Security baseline deployed from code (110 resources) | ~5 min |
| 2026-10-16 | Application stack deployed from code (68 resources) | 15 min |
| 2026-10-16 | Zero-downtime releases with circuit breaker (×2) | ~4 min each, no failed requests |
| 2026-10-16 | Incident-response drill (`make ir-drill`), GuardDuty crypto-mining simulation | Forensic snapshot + alert in seconds |
| 2026-10-16 | WAF rate-limit attack simulation (350 requests) | Blocked within ~20 s, 0 requests reached the app |
| 2026-10-16 | Full teardown (181 resources), zero leftovers verified | 18 min |
