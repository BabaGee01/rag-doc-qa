#!/usr/bin/env bash
# Incident-response drill. Sends a realistic GuardDuty Runtime Monitoring finding for a *live* task
# through the containment Lambda.
#   make ir-drill          -> dry run: forensic snapshot + alert email, task untouched
#   make ir-drill LIVE=1   -> real containment: task tagged and stopped, ECS replaces it
set -euo pipefail
PROJECT="$1" REGION="$2" LIVE="${LIVE:-0}"

TASK=$(aws ecs list-tasks --region "$REGION" --cluster "$PROJECT" --desired-status RUNNING --query 'taskArns[0]' --output text)
[[ "$TASK" == "None" || -z "$TASK" ]] && { echo "No running task in cluster $PROJECT"; exit 1; }
DRILL=$([[ "$LIVE" == "1" ]] && echo false || echo true)
echo "Target task: $TASK (drill/dry-run: $DRILL)"

EVENT=$(jq -n --arg task "$TASK" --arg cluster "$PROJECT" --argjson drill "$DRILL" '{
  drill: $drill,
  source: "aws.guardduty",
  "detail-type": "GuardDuty Finding",
  detail: {
    id: ("drill-" + (now | tostring)),
    type: "CryptoCurrency:Runtime/BitcoinTool.B",
    severity: 8,
    title: "[DRILL] Crypto-mining process detected in ECS task",
    resource: { resourceType: "ECSCluster", ecsClusterDetails: { name: $cluster, taskDetails: { arn: $task } } }
  }
}')

aws lambda invoke --region "$REGION" --function-name "$PROJECT-contain-ecs-task" \
  --cli-binary-format raw-in-base64-out --payload "$EVENT" /dev/stdout
echo
echo "Check your email for the containment alert, and the Lambda log for the forensic snapshot:"
echo "  aws logs tail /aws/lambda/$PROJECT-contain-ecs-task --since 5m --region $REGION"
[[ "$LIVE" == "1" ]] && echo "Watch ECS replace the task: aws ecs list-tasks --cluster $PROJECT --region $REGION"
