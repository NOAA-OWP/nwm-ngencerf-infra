locals {
  bucket_name = "${var.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"
  key_alias   = "alias/${var.name_prefix}-tfstate"
}

# KMS customer-managed key encrypts the state bucket.
# Customer-managed (vs AWS-managed) lets us:
#   - Tighten the key policy (only the role applying Terraform can decrypt)
#   - Control rotation policy
#   - Audit key usage via CloudTrail
resource "aws_kms_key" "tfstate" {
  description             = "Encrypts the ${local.bucket_name} state bucket"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "tfstate" {
  name          = local.key_alias
  target_key_id = aws_kms_key.tfstate.key_id
}

resource "aws_s3_bucket" "tfstate" {
  bucket        = local.bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.tfstate.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# State locking is handled by S3's native conditional-write lock
# (`use_lockfile = true` in backend.hcl). DynamoDB is NOT needed.
# That pattern is deprecated as of Terraform 1.10. See:
#   https://developer.hashicorp.com/terraform/language/backend/s3
#   https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/backend.html
