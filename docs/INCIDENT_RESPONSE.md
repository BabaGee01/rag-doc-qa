# Incident Response Runbook

Follows the NIST SP 800-61 lifecycle: **Prepare → Detect & Analyse → Contain → Eradicate & Recover → Post-incident**.

## Severity and response times

| Severity | Examples | Acknowledge | Who |
|---|---|---|---|
| **SEV1** | GuardDuty High/Critical on a running task (crypto-mining, reverse shell), root account use, CloudTrail stopped, API key abuse | 15 min | On-call engineer, then the security lead |
| **SEV2** | Security Hub Critical control failure, Inspector Critical CVE in the deployed image, a Config rule auto-remediated something | 4 hours | On-call engineer |
| **SEV3** | Medium findings, WAF block spikes, budget forecast alert | Next working day | Weekly review |

## How alerts arrive

| Signal | Path | Email subject starts with |
|---|---|---|
| GuardDuty severity ≥ 7 | EventBridge → SNS | `[GuardDuty severity …]` |
| Containment executed | Lambda → SNS | `[Containment]` |
| Security Hub Critical/High (controls, Inspector, Access Analyzer) | EventBridge → SNS | `[Security Hub …]` |
| CIS audit events (root use, MFA-less sign-in, IAM/CloudTrail/network changes) | CloudTrail → metric filter → alarm | `ALARM: "cis-…"` |
| Containment failed (DLQ) | SQS → alarm | `ALARM: "rag-doc-qa-containment-failed"` |
| Budget forecast exceeded | AWS Budgets → SNS | `AWS Budgets: …` |

All findings are also kept in the log group `/aws/events/security-findings` for one year.

---

## Playbook 1: compromised container (GuardDuty Runtime Monitoring)

*Examples: `CryptoCurrency:Runtime/BitcoinTool.B`, `Execution:Runtime/ReverseShell`, `Execution:Runtime/NewBinaryExecuted`*

**Automated (within ~1 minute of the finding):** the `rag-doc-qa-contain-ecs-task` Lambda logs a forensic snapshot
(image digest, task definition, private IP, start time), tags the task `security:quarantined=true`, and stops it. ECS starts a
clean replacement from the trusted image, and you receive a `[Containment]` email.

**Analyse:**
1. Open the finding in GuardDuty: process tree, command line, executable hash, remote IPs.
2. Read the forensic snapshot:
   ```bash
   aws logs tail /aws/lambda/rag-doc-qa-contain-ecs-task --since 1h
   ```
3. Was the **image** compromised, or the **running task**? Compare the image digest with the CI build for that commit. Check Inspector for critical CVEs in that digest.
4. Scope the blast radius:
   - VPC Flow Logs (`/aws/vpc/rag-doc-qa/flow-logs`): other destinations the task's private IP contacted.
   - CloudTrail: any AWS API calls by the task role. It has no permissions, so any call is itself an indicator.
   - WAF logs (`aws-waf-logs-rag-doc-qa`, us-east-1): requests just before the finding, which may show the exploit.

**Contain further, if needed:**
- If the image is bad: roll back to the last known-good commit (`make release IMAGE_TAG=<sha>`), and block the bad digest by deleting it from ECR.
- If the replacement task is also flagged, scale to zero: `aws ecs update-service --cluster rag-doc-qa --service rag-doc-qa --desired-count 0`.

**Eradicate & recover:**
- Rotate the Anthropic API key: revoke it in the Anthropic console, then `make secret` and `make release`.
- Patch the root cause (dependency bump or code fix), let CI's scans pass, and deploy.

## Playbook 2: leaked credentials or suspicious IAM activity

*Triggers: `UnauthorizedAccess:IAMUser/*`, `cis-root-account-usage`, `cis-console-signin-without-mfa`, `cis-unauthorized-api-calls`, unexpected budget alert*

1. Identify the principal and access key in the CloudTrail event (`userIdentity.accessKeyId`).
2. **Contain:** deactivate the key (`aws iam update-access-key --status Inactive`), and attach `AWSDenyAll` to the user or role if activity continues.
3. Review CloudTrail for everything that key did: new users, roles, keys, regions used, and resources created (crypto-mining usually means large EC2 instances in unused regions).
4. Delete persistence such as new IAM users, access keys, roles, Lambda functions or EventBridge rules.
5. Rotate every credential the principal could read.

## Playbook 3: failed compliance control or vulnerable image

1. Open the finding in Security Hub and read its remediation link.
2. Fix it in **Terraform**, never the console, so it doesn't drift back. Open a PR; CI's Checkov scan proves the fix.
3. For Inspector CVEs, bump the package or base image (Dependabot usually already has a PR), then `make release`.
4. Set the finding's workflow status: **RESOLVED** when fixed, or **SUPPRESSED** with a note referencing the risk register when accepted ([SECURITY.md](SECURITY.md#5-risk-acceptance-register)).

## Playbook 4: application-layer abuse

*Triggers: WAF block spikes, `rate-limit-ask` blocks, daily question cap reached*

1. Security dashboard → "Top blocked client IPs".
2. For targeted abuse, add the IPs to a WAF IP set block rule. For a broad bot wave, enable the Bot Control rule group.
3. Prompt-injection attempts in uploaded documents are expected and contained: uploads are visible only to the uploader's session, and the model is told to treat document text as data.

---

## Escalating to AWS

Engage the **AWS Security Incident Response** service (if subscribed) or open an AWS Support case when:
- AWS resources are being used to attack others (AWS Trust & Safety may also contact you), or
- you need help with forensic analysis beyond your own logs, or the account itself is at risk.

Hand over: finding IDs, the time window, affected resource ARNs, CloudTrail event IDs, and the actions already taken.

## Drills

Practise quarterly. The drill sends a realistic finding for a **live** task through the real containment path:

```bash
make ir-drill          # dry run: forensic snapshot + alert, task untouched
LIVE=1 make ir-drill   # real containment: watch the task get replaced
```

Also run `aws guardduty create-sample-findings --detector-id <id> --finding-types Execution:Runtime/ReverseShell` to
test alert routing end to end. Sample findings name a fake cluster, so they alert without triggering containment.

## Weekly review

Every Monday, with the automated posture report email:
1. Triage new Critical/High findings and set their workflow status.
2. Review **Trusted Advisor** security checks in the console (core checks are free).
3. Merge Dependabot PRs and check that the Inspector findings count is trending down.
4. Review the risk acceptance register: does anything need to be revisited?

## Post-incident review

Within 5 working days of any SEV1/SEV2, write a blameless review covering: timeline (detection, containment and
recovery times), impact, root cause, what worked, what didn't, and actions with owners. Add a regression test, a
Config rule or a Checkov check so the same issue can't recur silently.
