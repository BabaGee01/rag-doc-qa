import importlib.util
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "contain_ecs_task", Path(__file__).parents[1] / "infra/app/lambda/contain_ecs_task.py"
)
contain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contain)

TASK_ARN = "arn:aws:ecs:eu-west-2:111122223333:task/rag-doc-qa/abc123"


def finding(cluster="rag-doc-qa"):
    return {
        "detail": {
            "id": "f-1",
            "type": "CryptoCurrency:Runtime/BitcoinTool.B",
            "severity": 8,
            "title": "Crypto-mining process detected",
            "resource": {
                "resourceType": "ECSCluster",
                "ecsClusterDetails": {"name": cluster, "taskDetails": {"arn": TASK_ARN}},
            },
        }
    }


class FakeECS:
    def __init__(self, status="RUNNING"):
        self.status = status
        self.stopped, self.tagged = [], []

    def describe_tasks(self, cluster, tasks):
        return {
            "tasks": [
                {
                    "taskArn": tasks[0],
                    "lastStatus": self.status,
                    "containers": [{"name": "app", "image": "repo:sha", "imageDigest": "sha256:abc"}],
                    "attachments": [{"details": [{"name": "privateIPv4Address", "value": "10.40.10.5"}]}],
                }
            ]
        }

    def tag_resource(self, resourceArn, tags):
        self.tagged.append((resourceArn, tags))

    def stop_task(self, cluster, task, reason):
        self.stopped.append((task, reason))


class FakeSNS:
    def __init__(self):
        self.messages = []

    def publish(self, **kwargs):
        self.messages.append(kwargs)


@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("CLUSTER_NAME", "rag-doc-qa")
    monkeypatch.setenv("TOPIC_ARN", "arn:aws:sns:eu-west-2:111122223333:security-alerts")
    monkeypatch.setenv("DRY_RUN", "false")


def test_contains_task_in_our_cluster():
    ecs, sns = FakeECS(), FakeSNS()
    result = contain.handler(finding(), None, ecs=ecs, sns=sns)
    assert ecs.stopped and ecs.stopped[0][0] == TASK_ARN
    assert {"key": "security:guardduty-finding", "value": "f-1"} in ecs.tagged[0][1]
    assert "stopped" in result["action"]
    assert "sha256:abc" in sns.messages[0]["Message"]


def test_dry_run_changes_nothing(monkeypatch):
    monkeypatch.setenv("DRY_RUN", "true")
    ecs, sns = FakeECS(), FakeSNS()
    result = contain.handler(finding(), None, ecs=ecs, sns=sns)
    assert not ecs.stopped and not ecs.tagged
    assert result["action"].startswith("dry-run")
    assert sns.messages


def test_ignores_other_clusters():
    ecs, sns = FakeECS(), FakeSNS()
    assert contain.handler(finding(cluster="someone-else"), None, ecs=ecs, sns=sns) == {"action": "ignored"}
    assert not ecs.stopped and not sns.messages


def test_already_stopped_task_is_not_stopped_again():
    ecs, sns = FakeECS(status="STOPPED"), FakeSNS()
    contain.handler(finding(), None, ecs=ecs, sns=sns)
    assert not ecs.stopped


def test_drill_event_is_dry_run_even_when_containment_enabled():
    ecs, sns = FakeECS(), FakeSNS()
    result = contain.handler({**finding(), "drill": True}, None, ecs=ecs, sns=sns)
    assert not ecs.stopped and result["action"].startswith("dry-run")
