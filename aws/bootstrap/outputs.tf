# Outputs in alphabetical order (HashiCorp Style Guide).

output "kms_key_alias" {
  value       = aws_kms_alias.tfstate.name
  description = "KMS key alias used to encrypt the state bucket."
}

output "kms_key_arn" {
  value       = aws_kms_key.tfstate.arn
  description = "KMS key ARN for advanced reference."
}

output "region" {
  value       = var.region
  description = "Region the state backend lives in."
}

output "state_bucket" {
  value       = aws_s3_bucket.tfstate.bucket
  description = "S3 bucket for Terraform state."
}
