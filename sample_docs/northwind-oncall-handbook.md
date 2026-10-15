# Northwind Cloud - Platform On-Call Handbook

*Fictional sample document for the RAG Doc Q&A demo.*

## 1. Who is on call

The Platform team runs a follow-the-sun rotation with one primary and one secondary engineer per shift. Shifts are 12 hours: the London shift runs 07:00-19:00 UTC and the Toronto shift runs 19:00-07:00 UTC. Rotations change every Monday at 09:00 UTC, and the outgoing primary must hold a 15-minute handover call with the incoming primary.

New engineers shadow two full rotations before joining as secondary, and must complete one rotation as secondary before becoming primary.

## 2. Severity levels

- **SEV1** - Customer-facing outage or data loss affecting more than 5% of customers. Acknowledge within 5 minutes. The Incident Commander must page the Head of Engineering and open a status page incident within 15 minutes.
- **SEV2** - Degraded service (for example p95 latency above 2 seconds for 10 minutes, or a single region down with failover working). Acknowledge within 15 minutes.
- **SEV3** - Internal tooling broken or a non-urgent bug with a workaround. Handle during business hours; no page is sent.

If you are unsure of the severity, declare the higher one. Downgrading later is cheap; under-reacting is not.

## 3. Responding to a page

1. Acknowledge the page in PagerDuty so it does not escalate. Unacknowledged pages escalate to the secondary after 10 minutes and to the Engineering Manager after 20 minutes.
2. Join the #inc-bridge Slack channel and post "Investigating" with the alert name.
3. For SEV1 and SEV2, the first responder becomes Incident Commander (IC) until they explicitly hand the role over. The IC coordinates; they should not also be the person typing commands.
4. Check the "Golden Signals" Grafana dashboard: latency, traffic, errors and saturation for the affected service.
5. Prefer rollback over roll-forward. If a deploy happened in the last 2 hours, roll it back first and investigate afterwards.

## 4. Common runbooks

### 4.1 Kubernetes pods in CrashLoopBackOff

Run `kubectl describe pod` and check the last termination reason. `OOMKilled` means the memory limit is too low: raise it by at most 50% via the Helm values file, never by editing the live deployment. For configuration errors, compare the ConfigMap against the last known-good Git commit in the gitops repository.

### 4.2 RDS storage almost full

An alert fires when free storage drops below 15%. Storage autoscaling is enabled up to 2 TB, so first confirm autoscaling has not hit that ceiling. If it has, open a SEV2 and contact the Data team; do not delete tables or logs to free space.

### 4.3 Expired TLS certificate

Certificates are issued by cert-manager and renew 30 days before expiry. If one has expired, check the cert-manager logs for failed ACME challenges - the usual cause is a DNS record changed outside Terraform.

## 5. After the incident

Every SEV1 and SEV2 requires a blameless post-incident review within 5 business days. The IC owns the document, which must include a timeline, customer impact, contributing factors and at least one action item with an owner and due date. Reviews are presented at the Thursday reliability meeting.

## 6. Compensation and wellbeing

On-call engineers receive a flat stipend of GBP 250 (or CAD 425 for Toronto) per week on call, plus time off in lieu: any engineer paged between 23:00 and 06:00 local time may start work up to 4 hours late the next day. Nobody should be on call for more than one week in any four-week period. If you are unwell or have a personal emergency during your shift, swap with the secondary and notify your manager - no justification is needed.
