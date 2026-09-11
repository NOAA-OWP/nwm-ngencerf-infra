terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # First apply ran on local state (no backend block). After that apply created
  # the bucket+KMS key, this empty `backend "s3" {}` block enables migration:
  #   terraform init -backend-config=backend.hcl -migrate-state
  # Runtime values (bucket, key, region, kms_key_id) live in backend.hcl.
  backend "s3" {}
}
