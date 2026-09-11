.PHONY: help init plan apply destroy bootstrap load-static smoke fmt lint pre-commit-install _check_env

ENV ?= sandbox
TERRAFORM_DIR := aws/envs/$(ENV)

help:
	@echo "Targets (pass ENV=<env>, default sandbox):"
	@echo "  Valid envs: sandbox, ea, uat2"
	@echo ""
	@echo "  init                - terraform init (uses env's backend.hcl)"
	@echo "  plan                - terraform plan"
	@echo "  apply               - terraform apply"
	@echo "  destroy             - terraform destroy"
	@echo "  bootstrap           - stage workload SIFs + ngen static data onto EFS (after apply)"
	@echo "  load-static         - re-sync ngen static data onto EFS (static-data stage only)"
	@echo "  smoke               - end-to-end smoke test"
	@echo "  fmt                 - terraform fmt -recursive"
	@echo "  lint                - tflint + checkov"
	@echo "  pre-commit-install  - install pre-commit hooks (one-time)"
	@echo ""
	@echo "Usage: make plan ENV=ea"
	@echo ""
	@echo "Bootstrap (one-time per AWS account, see aws/bootstrap/README.md):"
	@echo "  cd aws/bootstrap && terraform init && terraform apply"

_check_env:
	@if [ ! -d "$(TERRAFORM_DIR)" ]; then \
		echo "ERROR: env '$(ENV)' not found. Valid: sandbox, ea, uat2"; \
		exit 1; \
	fi

init: _check_env
	cd $(TERRAFORM_DIR) && terraform init -backend-config=backend.hcl

plan: _check_env
	cd $(TERRAFORM_DIR) && terraform plan

apply: _check_env
	cd $(TERRAFORM_DIR) && terraform apply

bootstrap: _check_env
	bash aws/scripts/bootstrap.sh $(ENV)

load-static: _check_env
	bash aws/scripts/bootstrap.sh $(ENV) static

destroy: _check_env
	cd $(TERRAFORM_DIR) && terraform destroy

smoke: _check_env
	bash aws/scripts/smoke.sh $(ENV)

fmt:
	terraform fmt -recursive aws

lint:
	cd aws && tflint --recursive
	checkov -d aws --quiet --compact

pre-commit-install:
	pre-commit install
