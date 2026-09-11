provider "aws" {
  region = "us-east-1"

  # Single source of tags (local.common_tags in main.tf), used here for every
  # aws-provider resource AND passed to the module as var.tags so the awscc PCS
  # resources (which ignore default_tags) carry the identical set, including the
  # Team tag the Sandbox account enforces via SCP.
  default_tags {
    tags = local.common_tags
  }
}

# awscc (AWS Cloud Control) provider: hosts the AWS PCS resources in pcs.tf.
# The awscc provider does not support the aws provider's default_tags, so the
# PCS resources are tagged via an explicit tags input passed to the module.
# Region must match the aws provider.
provider "awscc" {
  region = "us-east-1"
}
