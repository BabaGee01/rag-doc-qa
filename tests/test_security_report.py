import importlib.util
from datetime import UTC, datetime
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "security_report", Path(__file__).parents[1] / "infra/security-baseline/lambda/security_report.py"
)
security_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(security_report)


def control(status, control_id="S3.1", sev="MEDIUM"):
    return {
        "Title": f"{control_id} title",
        "Severity": {"Label": sev},
        "Compliance": {"Status": status, "SecurityControlId": control_id},
        "ProductName": "Security Hub",
    }


def test_report_scores_and_ranks_failures():
    controls = [
        control("PASSED"),
        control("PASSED"),
        control("FAILED", "EC2.2", "HIGH"),
        control("FAILED", "EC2.2", "HIGH"),
    ]
    open_findings = [
        control("FAILED", "EC2.2", "HIGH"),
        {"Severity": {"Label": "CRITICAL"}, "ProductName": "Inspector"},
    ]
    report = security_report.build_report(controls, open_findings, datetime(2026, 10, 19, tzinfo=UTC))
    assert "Compliance score: 50% (2 passed / 2 failed" in report
    assert "CRITICAL  1" in report
    assert "[HIGH] EC2.2: EC2.2 title (2 resources)" in report
    assert "Inspector" in report


def test_report_with_no_failures():
    report = security_report.build_report([control("PASSED")], [], datetime(2026, 10, 19, tzinfo=UTC))
    assert "Compliance score: 100%" in report
    assert "all evaluated controls are passing" in report
