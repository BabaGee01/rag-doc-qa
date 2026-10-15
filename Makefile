SHELL := /bin/bash
PROJECT ?= rag-doc-qa
AWS_REGION ?= $(shell aws configure get region || echo eu-west-2)
ACCOUNT_ID = $(shell aws sts get-caller-identity --query Account --output text)
STATE_BUCKET = tfstate-$(ACCOUNT_ID)-$(AWS_REGION)
BACKEND = -backend-config="bucket=$(STATE_BUCKET)" -backend-config="region=$(AWS_REGION)"
# Immutable image tag: commit SHA (+ timestamp if the tree has uncommitted changes)
IMAGE_TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)$(shell git diff --quiet 2>/dev/null || echo -$$(date +%Y%m%d%H%M%S))

.PHONY: help install test lint scan run docker-run secret bootstrap security app deploy release url \
        logs ir-drill security-report destroy destroy-app

help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

# ---------- local development ----------
install: ## Create venv and install dev dependencies
	python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt

test: ## Run unit tests
	.venv/bin/pytest -q

lint: ## Lint and format-check
	.venv/bin/ruff check . && .venv/bin/ruff format --check .

scan: ## Local security scans: Checkov (IaC) + Trivy (image) + pip-audit (deps)
	docker run --rm -v "$(PWD)":/src -w /src bridgecrew/checkov -d . --config-file .checkov.yaml --quiet --compact
	docker build -q -t $(PROJECT):scan . >/dev/null
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache aquasec/trivy image \
	  --db-repository public.ecr.aws/aquasecurity/trivy-db:2 --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $(PROJECT):scan
	docker run --rm -v "$(PWD)":/src -w /src python:3.12-slim sh -c "pip -q install pip-audit && pip-audit -r requirements.txt"

run: ## Run locally on http://localhost:8000 (reads .env)
	set -a; [ -f .env ] && source .env; set +a; .venv/bin/uvicorn app.main:create_app --factory --reload --port 8000

docker-run: ## Build and run the hardened container locally (read-only, no capabilities)
	docker build -t $(PROJECT) . && docker run --rm -p 8000:8000 --env-file .env \
	  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges $(PROJECT)

# ---------- AWS ----------
secret: ## Store your Anthropic API key in SSM Parameter Store (prompts, not echoed)
	@read -rsp "Anthropic API key: " KEY && echo && \
	aws ssm put-parameter --region $(AWS_REGION) --name /$(PROJECT)/anthropic-api-key \
	  --type SecureString --overwrite --value "$$KEY" >/dev/null && echo "Stored /$(PROJECT)/anthropic-api-key"

bootstrap: ## 1. Create the encrypted Terraform state bucket (once per account)
	terraform -chdir=infra/bootstrap init -input=false
	terraform -chdir=infra/bootstrap apply -input=false

security: ## 2. Deploy the account security baseline (needs infra/security-baseline/terraform.tfvars)
	terraform -chdir=infra/security-baseline init -input=false -reconfigure $(BACKEND)
	terraform -chdir=infra/security-baseline apply -input=false

app: ## 3. Deploy the application stack (builds and pushes the image first)
	terraform -chdir=infra/app init -input=false -reconfigure $(BACKEND)
	terraform -chdir=infra/app apply -input=false -target=aws_ecr_repository.app -var image_tag=$(IMAGE_TAG)
	$(MAKE) push IMAGE_TAG=$(IMAGE_TAG)
	terraform -chdir=infra/app apply -input=false -var image_tag=$(IMAGE_TAG)
	@echo; echo "App URL: $$(terraform -chdir=infra/app output -raw app_url)  (CloudFront takes ~5 minutes to deploy globally)"

deploy: bootstrap security app ## Full deploy: bootstrap -> security baseline -> app

push:
	$(eval REPO := $(shell terraform -chdir=infra/app output -raw ecr_repository_url))
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(firstword $(subst /, ,$(REPO)))
	docker buildx build --platform linux/amd64 --push --provenance=true --sbom=true -t $(REPO):$(IMAGE_TAG) .

release: ## Ship code changes: push a new immutable image and roll the ECS service to it
	$(MAKE) push IMAGE_TAG=$(IMAGE_TAG)
	./scripts/release.sh $(PROJECT) $(AWS_REGION) $$(terraform -chdir=infra/app output -raw ecr_repository_url):$(IMAGE_TAG)

url: ## Print the public URL and security dashboard
	@terraform -chdir=infra/app output -raw app_url; echo
	@terraform -chdir=infra/app output -raw security_dashboard_url; echo

logs: ## Tail application logs
	aws logs tail /ecs/$(PROJECT) --follow --region $(AWS_REGION)

security-report: ## Send the weekly security posture report now
	aws lambda invoke --region $(AWS_REGION) --function-name security-posture-report /dev/stdout

ir-drill: ## Incident-response drill: simulate a GuardDuty crypto-mining finding on a live task (DRY_RUN)
	./scripts/ir-drill.sh $(PROJECT) $(AWS_REGION)

destroy-app: ## Tear down the app stack only (keeps the security baseline)
	terraform -chdir=infra/app init -input=false -reconfigure $(BACKEND)
	terraform -chdir=infra/app destroy -input=false -var image_tag=destroy

destroy: destroy-app ## Tear down app + security baseline (state bucket is kept)
	terraform -chdir=infra/security-baseline init -input=false -reconfigure $(BACKEND)
	terraform -chdir=infra/security-baseline destroy -input=false
