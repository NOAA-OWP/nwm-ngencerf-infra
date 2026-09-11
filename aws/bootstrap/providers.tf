provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "ngencerf"
      ManagedBy = "Terraform"
      Repo      = "nwm-ngencerf-infra"
      Component = "tfstate-backend"
    }
  }
}

data "aws_caller_identity" "current" {}
