# envs/sandbox/main.tf: NGWPC Sandbox account, LZA-governed.
# Consumes the existing private-only "SBOX-Compute" VPC via data sources
# (same pattern as envs/test/*). No public subnets, no IGW, no NAT in this
# VPC. Egress is via Transit Gateway, and an LZA S3 gateway endpoint already
# exists. The ALB is therefore internal (alb_internal = true) and rides on the
# private subnets; reach it over the TGW path. The custom PCS compute AMI is
# built in-account (build_compute_ami = true) because an AMI is account-scoped,
# so each account bakes its own. The compute node groups read that freshly
# baked AMI directly, so a single apply builds AND uses it (no manual pin)
# (see the enable_pcs block below).

# Common tag set, single-sourced here. Used by the provider default_tags
# (providers.tf) for all aws-provider resources AND passed to the module
# (tags = local.common_tags) so the awscc PCS resources, which default_tags
# can't reach, carry the same tags. Team is the value the Sandbox account
# enforces via SCP; POC is a contactable owner per the Sandbox rules of the road.
locals {
  common_tags = {
    Project     = "ngencerf"
    ManagedBy   = "Terraform"
    Repo        = "nwm-ngencerf-infra"
    Team        = "nwm"
    POC         = "Miguel Pena"
    Owner       = var.owner
    Environment = "sandbox"
  }
}

data "aws_vpc" "sbox" {
  filter {
    name   = "tag:Name"
    values = ["SBOX-Compute"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.sbox.id]
  }
  filter {
    name   = "tag:Name"
    values = ["sbox-compute-*"]
  }
}

module "ngencerf" {
  source = "../../modules/ngencerf"

  name_prefix = "ngencerf-sandbox"

  # Same tag map providers.tf feeds to default_tags; the module applies it to the
  # awscc PCS resources (and launched instances/volumes + the built AMI) that
  # default_tags can't reach.
  tags = local.common_tags

  vpc_id             = data.aws_vpc.sbox.id
  private_subnet_ids = data.aws_subnets.private.ids
  public_subnet_ids  = []

  # Private-only VPC: no public subnets exist, so the ALB is internal and
  # binds to the private subnets. Reach it via the VPC / Transit Gateway path.
  alb_internal = true

  production = false

  # Team Amazon WorkSpaces (Test account, both AZ subnets = 10.6.2.0/24)
  # reach RDS Postgres directly for testing. Module default is empty, so
  # prod-tier envs keep the DB reachable only from the app.
  db_ingress_cidrs = ["10.6.2.0/24"]

  # PCS (managed Slurm) on, with the compute AMI built in-account: build_compute_ami
  # runs the Image Builder pipeline (~20-30 min on the FIRST apply) and the compute
  # node groups read that freshly baked AMI directly, so ONE apply builds and uses it,
  # no manual pin. (An AMI is account-scoped, so each account bakes its own.)
  # Leave build_compute_ami = true to keep the custom AMI; it only re-bakes when the
  # image recipe version changes, not on every apply. pcs_compute_ami_id stays empty
  # unless you want to force a specific external AMI.
  enable_pcs         = true
  build_compute_ami  = true
  pcs_compute_ami_id = ""

  # Instance types backing the two Slurm partitions (c5n-9xlarge / r8a-12xlarge).
  # Uniform prod sizing; both autoscale from 0 (no idle cost).
  pcs_compute_default_instance_type = "c5n.9xlarge"
  pcs_compute_heavy_instance_type   = "r8a.12xlarge"

  # ngencerf-server and ngencerf-ui Docker images
  ngencerf_server_image = "ghcr.io/ngwpc/ngencerf-server:20260818172414Z-development"
  ngencerf_ui_image     = "ghcr.io/ngwpc/ngencerf-ui:20260818172353Z-development"

  # S3 archive + zip storage prefixes (shared Data-account buckets). Each env
  # uses its own unique prefix; seed a .keep object in each prefix so it exists
  # before the first archive or zip is written.
  ngencerf_archive_s3_path = "s3://ngwpc-ngencerf-archive/sandbox/"
  ngencerf_zips_s3_path    = "s3://ngwpc-ngencerf-zips/sandbox/"

  # EDFS (NOAA Enterprise Data Services): Sandbox uses the Test data services.
  # Required by save_gage_tab (unset -> ValueError "Invalid environment: 'None'").
  # The host resolves from this VPC only once EDFS DNS is wired (a Route 53
  # resolver rule / private hosted zone) into SBOX-Compute.
  enterprise_data_url = "http://edfs.test.nextgenwaterprediction.com/"
  enterprise_data_env = "test"

  # Active Directory / LDAP auth against the NGWPC AWS Managed Microsoft AD.
  # Off in the module by default; sandbox opts in. The bind PASSWORD comes from
  # the existing Secrets Manager secret svc-ldap-ro-testdev (read-only AD service
  # account, created outside this stack) via its "password" key, so it never
  # enters Terraform state. LDAP_SYSTEM_NAME = "dev" means the server admits
  # members of ngencerf-dev-users (staff: ngencerf-dev-admins). Server URI uses
  # the AD DNS name (Kevin added a Route 53 record resolving it inside
  # SBOX-Compute), not a pinned DC IP, so AD can fail over across controllers;
  # plain LDAP on 389.
  enable_active_directory = true
  ldap_server_uri         = "ldap://nextgenwaterprediction.com"
  ldap_system_name        = "dev"
  ldap_bind_dn            = "svc-ldap-ro-testdev@nextgenwaterprediction.com"
  ldap_bind_secret_name   = "svc-ldap-ro-testdev"

  # Mandatory MFA layered on top of the AD password check. Applies to every
  # user, AD-backed included: each one enrolls an authenticator app on next login
  # and gets recovery codes. Enrollment lives in the database, so destroying this
  # env wipes it and everyone re-enrolls on the next bring-up.
  enable_mfa = true

  # Workload SIFs staged onto EFS by `make bootstrap` (sif_sync.tf): name -> OCI tag.
  sif_workloads = {
    "nwm-cal-mgr"  = "20260818142627Z-development"
    "nwm-fcst-mgr" = "20260818142625Z-development"
    "nwm-eval-mgr" = "20260730211204Z-development"
  }

  rds_instance_class        = "db.r7g.large"
  rds_allocated_storage_gib = 200
  redis_node_type           = "cache.r7g.large"
}
