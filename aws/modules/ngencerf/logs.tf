# CloudWatch log groups for ECS services.
# One log group per service; eager-created because ECS does not auto-create
# them on first task start. Retention 365d matches the LZA org-wide default
# (NGWPC's FedRAMP Moderate posture). Encrypted with the env CMK so logs sit
# on the same key audit surface as the rest of the stack.
# AU-11: audit record retention. AU-12: audit record generation.
# SC-28: at-rest encryption with customer-managed key.

resource "aws_cloudwatch_log_group" "django" {
  name              = "/aws/ecs/${var.name_prefix}/django"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "nuxt" {
  name              = "/aws/ecs/${var.name_prefix}/nuxt"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn
}

# WAF logging target. Name MUST start with "aws-waf-logs-". AWS WAF service
# rejects PutLoggingConfiguration if the log group name doesn't match that
# prefix. The KMS key policy in secrets.tf grants the logs service principal
# access to this group name explicitly.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name_prefix}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn
}
