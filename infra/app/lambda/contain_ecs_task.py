"""Contain a compromised ECS task flagged by GuardDuty Runtime Monitoring.

1. Capture forensic metadata (image digest, network, timings) to the log before anything changes.
2. Tag the task with the finding ID so it is traceable in the console and CloudTrail.
3. Stop the task. The ECS service replaces it with a fresh task from the trusted image.
4. Notify the security topic with what was done and the next manual steps.

Set DRY_RUN=true to rehearse (tabletop exercises): steps 1 and 4 run, nothing is changed.
"""

from __future__ import annotations

import json
import os


def extract_target(event: dict, cluster_name: str) -> dict | None:
    detail = event.get("detail", {})
    ecs = detail.get("resource", {}).get("ecsClusterDetails", {})
    task_arn = ecs.get("taskDetails", {}).get("arn")
    if ecs.get("name") != cluster_name or not task_arn:
        return None
    return {
        "task_arn": task_arn,
        "finding_id": detail.get("id", "unknown"),
        "finding_type": detail.get("type", "unknown"),
        "severity": detail.get("severity"),
        "title": detail.get("title", ""),
    }


def forensic_snapshot(task: dict) -> dict:
    return {
        "taskArn": task.get("taskArn"),
        "taskDefinitionArn": task.get("taskDefinitionArn"),
        "lastStatus": task.get("lastStatus"),
        "startedAt": str(task.get("startedAt")),
        "availabilityZone": task.get("availabilityZone"),
        "containers": [
            {"name": c.get("name"), "image": c.get("image"), "imageDigest": c.get("imageDigest")}
            for c in task.get("containers", [])
        ],
        "network": [
            {d["name"]: d["value"] for d in a.get("details", []) if d.get("name") in ("privateIPv4Address", "subnetId")}
            for a in task.get("attachments", [])
        ],
    }


def handler(event, context, ecs=None, sns=None):
    if ecs is None or sns is None:
        import boto3  # provided by the Lambda runtime

        ecs, sns = ecs or boto3.client("ecs"), sns or boto3.client("sns")
    cluster = os.environ["CLUSTER_NAME"]
    # Drills (scripts/ir-drill.sh) set "drill": true; real GuardDuty events never carry this key.
    dry_run = os.environ.get("DRY_RUN", "false").lower() == "true" or event.get("drill") is True

    target = extract_target(event, cluster)
    if target is None:
        print(json.dumps({"action": "ignored", "reason": "finding is not for a task in this cluster"}))
        return {"action": "ignored"}

    tasks = ecs.describe_tasks(cluster=cluster, tasks=[target["task_arn"]]).get("tasks", [])
    snapshot = forensic_snapshot(tasks[0]) if tasks else {"taskArn": target["task_arn"], "note": "task not found"}
    print(json.dumps({"stage": "forensic-snapshot", "finding": target, "task": snapshot}, default=str))

    already_stopped = not tasks or tasks[0].get("lastStatus") == "STOPPED"
    if dry_run:
        action = "dry-run (no changes made)"
    elif already_stopped:
        action = "none (task already stopped)"
    else:
        ecs.tag_resource(
            resourceArn=target["task_arn"],
            tags=[
                {"key": "security:quarantined", "value": "true"},
                {"key": "security:guardduty-finding", "value": target["finding_id"]},
            ],
        )
        ecs.stop_task(
            cluster=cluster,
            task=target["task_arn"],
            reason=f"Security containment: GuardDuty {target['finding_type']}"[:255],
        )
        action = "task tagged and stopped; ECS is replacing it from the trusted image"

    sns.publish(
        TopicArn=os.environ["TOPIC_ARN"],
        Subject=f"[Containment] {target['finding_type']}"[:100],
        Message="\n".join(
            [
                f"GuardDuty finding: {target['title']} (severity {target['severity']})",
                f"Finding ID: {target['finding_id']}",
                f"Task: {target['task_arn']}",
                f"Image digest: {', '.join(str(c['imageDigest']) for c in snapshot.get('containers', []))}",
                f"Action taken: {action}",
                "",
                "Next steps (docs/INCIDENT_RESPONSE.md): scope via CloudTrail and VPC Flow Logs,",
                "check whether the image digest is affected (Inspector), rotate the Anthropic API key,",
                "then record a post-incident review.",
            ]
        ),
    )
    print(json.dumps({"stage": "complete", "action": action}))
    return {"action": action, "task": target["task_arn"]}
