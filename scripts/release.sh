#!/usr/bin/env bash
# Register a new task definition revision with the given image and roll the ECS service to it.
# The deployment circuit breaker rolls back automatically if the new tasks fail health checks.
set -euo pipefail
PROJECT="$1" REGION="$2" IMAGE="$3"

aws ecs describe-task-definition --region "$REGION" --task-definition "$PROJECT" --query taskDefinition \
  | jq --arg img "$IMAGE" '.containerDefinitions[0].image = $img
      | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)' \
  > /tmp/"$PROJECT"-taskdef.json

ARN=$(aws ecs register-task-definition --region "$REGION" --cli-input-json file:///tmp/"$PROJECT"-taskdef.json \
  --query taskDefinition.taskDefinitionArn --output text)
rm -f /tmp/"$PROJECT"-taskdef.json
echo "Registered $ARN"

aws ecs update-service --region "$REGION" --cluster "$PROJECT" --service "$PROJECT" --task-definition "$ARN" >/dev/null
echo "Rolling out... (waiting for the service to stabilise)"
aws ecs wait services-stable --region "$REGION" --cluster "$PROJECT" --services "$PROJECT"
echo "Deployed $IMAGE"
