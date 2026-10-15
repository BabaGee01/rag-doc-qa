"""Weekly security posture report from Security Hub, delivered by SNS email."""

from __future__ import annotations

import os
from collections import Counter
from datetime import UTC, datetime

SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]


def _findings(securityhub, filters: dict) -> list[dict]:
    findings: list[dict] = []
    for page in securityhub.get_paginator("get_findings").paginate(Filters=filters, MaxResults=100):
        findings.extend(page["Findings"])
    return findings


def _active(**extra) -> dict:
    return {"RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}], **extra}


def build_report(control_findings: list[dict], open_findings: list[dict], now: datetime) -> str:
    passed = sum(1 for f in control_findings if f.get("Compliance", {}).get("Status") == "PASSED")
    failed = [f for f in control_findings if f.get("Compliance", {}).get("Status") == "FAILED"]
    score = round(100 * passed / (passed + len(failed))) if passed + len(failed) else 100

    by_severity = Counter(f["Severity"]["Label"] for f in open_findings)
    by_product = Counter(f.get("ProductName", "Unknown") for f in open_findings)

    failing_controls = Counter()
    titles: dict[str, tuple[str, str]] = {}
    for f in failed:
        control = f.get("Compliance", {}).get("SecurityControlId") or f.get("GeneratorId", "?")
        failing_controls[control] += 1
        titles[control] = (f["Title"], f["Severity"]["Label"])

    lines = [
        f"Security posture report - {now:%A %d %B %Y}",
        "",
        f"Compliance score: {score}% ({passed} passed / {len(failed)} failed control checks)",
        "",
        "Open findings (workflow NEW or NOTIFIED) by severity:",
        *[f"  {sev:<9} {by_severity.get(sev, 0)}" for sev in SEVERITIES],
        "",
        "Open findings by source:",
        *[f"  {product:<20} {count}" for product, count in by_product.most_common()],
        "",
        "Top failing controls:",
    ]
    if failing_controls:
        for control, count in failing_controls.most_common(10):
            title, sev = titles[control]
            lines.append(f"  [{sev}] {control}: {title} ({count} resource{'s' if count != 1 else ''})")
    else:
        lines.append("  None - all evaluated controls are passing.")
    lines += [
        "",
        "Next steps: triage Critical/High first (docs/INCIDENT_RESPONSE.md). Mark accepted risks as",
        "SUPPRESSED with a note so they drop out of this report.",
    ]
    return "\n".join(lines)


def handler(event, context):
    import boto3

    securityhub = boto3.client("securityhub")
    control_findings = _findings(securityhub, _active(ProductName=[{"Value": "Security Hub", "Comparison": "EQUALS"}]))
    open_findings = _findings(
        securityhub,
        _active(
            WorkflowStatus=[
                {"Value": "NEW", "Comparison": "EQUALS"},
                {"Value": "NOTIFIED", "Comparison": "EQUALS"},
            ],
            SeverityLabel=[{"Value": s, "Comparison": "EQUALS"} for s in SEVERITIES],
        ),
    )
    report = build_report(control_findings, open_findings, datetime.now(UTC))
    boto3.client("sns").publish(
        TopicArn=os.environ["TOPIC_ARN"], Subject="Weekly AWS security posture report", Message=report
    )
    return {"open_findings": len(open_findings)}
