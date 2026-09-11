# envs/uat2/main.tf: UAT2 customer-acceptance env, NGWPC Test account,
# LZA-governed. Consumes the existing private-only "Test-ngen-Compute" VPC via
# data sources (same pattern as envs/sandbox). No public subnets, no IGW, no
# NAT in this VPC; egress rides the Transit Gateway and an LZA S3 gateway
# endpoint already exists, so the ALB is internal (alb_internal = true) on the
# private subnets. Public reach comes from the centralized edge instead: the
# public ALB in the Network account (behind WAF) forwards to an NLB in this
# account, and that NLB targets this env's internal ALB. Users arrive at
# https://ngencerf-uat2.nextgenwaterprediction.com, which resolves to the public
# edge. The custom PCS compute AMI is built in-account (build_compute_ami =
# true) because an AMI is account-scoped; ea and uat2 share this VPC but are
# fully separate stacks (own state, own name_prefix, own security groups).

# Common tag set, single-sourced here. Used by the provider default_tags
# (providers.tf) for all aws-provider resources AND passed to the module
# (tags = local.common_tags) so the awscc PCS resources, which default_tags
# can't reach, carry the same tags.
locals {
  common_tags = {
    Project     = "ngencerf"
    ManagedBy   = "Terraform"
    Repo        = "nwm-ngencerf-infra"
    Team        = "nwm"
    POC         = "Miguel Pena"
    Owner       = var.owner
    Environment = "uat2"
  }
}

data "aws_vpc" "ngen" {
  filter {
    name   = "tag:Name"
    values = ["Test-ngen-Compute"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.ngen.id]
  }
  filter {
    name   = "tag:Name"
    values = ["ngen-compute-*"]
  }
}

module "ngencerf" {
  source = "../../modules/ngencerf"

  name_prefix = "ngencerf-uat2"

  # Same tag map providers.tf feeds to default_tags; the module applies it to the
  # awscc PCS resources (and launched instances/volumes + the built AMI) that
  # default_tags can't reach.
  tags = local.common_tags

  vpc_id             = data.aws_vpc.ngen.id
  private_subnet_ids = data.aws_subnets.private.ids
  public_subnet_ids  = []

  # Private-only VPC: no public subnets exist, so the ALB is internal and binds
  # to the private subnets. The centralized public edge (public ALB -> NLB in
  # this account) delivers internet traffic to it.
  alb_internal = true

  # Customer-facing env: production-safe defaults on (multi-AZ RDS, deletion
  # protection, force_destroy off) and the WAF enforcing (block, not count).
  production      = true
  waf_rule_action = "count"

  # PCS (managed Slurm) on, with the compute AMI built in-account: build_compute_ami
  # runs the Image Builder pipeline (~20-30 min on the FIRST apply) and the compute
  # node groups read that freshly baked AMI directly, so ONE apply builds and uses it,
  # no manual pin. (An AMI is account-scoped, so each account bakes its own.)
  enable_pcs        = true
  build_compute_ami = true
  # AMI pinned to avoid unexpected rebuilds on applies
  pcs_compute_ami_id = "ami-0bdddc54459951432"

  # Instance types backing the two Slurm partitions (c5n-9xlarge / r8a-12xlarge).
  # Uniform prod sizing; both autoscale from 0 (no idle cost).
  pcs_compute_default_instance_type = "c5n.9xlarge"
  pcs_compute_heavy_instance_type   = "r8a.12xlarge"

  # ngencerf-server and ngencerf-ui Docker images. Public-facing envs pin
  # immutable timestamped tags, never a mutable alias like latest.
  ngencerf_server_image = "ghcr.io/ngwpc/ngencerf-server:20260818172414Z-development"
  ngencerf_ui_image     = "ghcr.io/ngwpc/ngencerf-ui:20260818172353Z-development"

  # The public origin users reach this env at. Sets the Django CSRF trusted
  # origin + X-Forwarded-Proto trust and points the UI's browser-facing API
  # base at the public host (the browser cannot reach the internal ALB DNS).
  public_url    = "https://ngencerf-uat2.nextgenwaterprediction.com"
  allowed_hosts = ["ngencerf-uat2.nextgenwaterprediction.com"]

  # S3 archive + zip storage prefixes (shared Data-account buckets). Each env
  # uses its own unique prefix; seed a .keep object in each prefix so it exists
  # before the first archive or zip is written.
  ngencerf_archive_s3_path = "s3://ngwpc-ngencerf-archive/uat2/"
  ngencerf_zips_s3_path    = "s3://ngwpc-ngencerf-zips/uat2/"

  # EDFS (NOAA Enterprise Data Services): this env lives in the Test account,
  # so it uses the Test data services. Required by save_gage_tab. The host must
  # resolve from the Test-ngen-Compute VPC (Route 53 private-hosted-zone
  # association plus EDFS allow-list, same wiring the sandbox VPC received).
  enterprise_data_url = "http://edfs.test.nextgenwaterprediction.com/"
  enterprise_data_env = "test"

  # Active Directory / LDAP auth against the NGWPC AWS Managed Microsoft AD,
  # with mandatory MFA on top. Mirrors the sandbox wiring (dev directory
  # group set + the svc-ldap-ro-testdev read-only bind account) until the
  # UAT2-specific group naming and bind secret are confirmed; the bind secret
  # must exist in THIS account's Secrets Manager before the first apply.
  enable_active_directory = true
  ldap_server_uri         = "ldap://nextgenwaterprediction.com"
  ldap_system_name        = "dev"
  ldap_bind_dn            = "svc-ldap-ro-testdev@nextgenwaterprediction.com"
  ldap_bind_secret_name   = "svc-ldap-ro-testdev"

  # Mandatory MFA layered on top of the AD password check. Every user enrolls
  # an authenticator app on next login and receives recovery codes.
  enable_mfa = true

  # Workload SIFs staged onto EFS by `make bootstrap` (sif_sync.tf): name -> OCI tag.
  # Pinned timestamped builds, same rule as the images above.
  sif_workloads = {
    "nwm-cal-mgr"  = "20260818142627Z-development"
    "nwm-fcst-mgr" = "20260818142625Z-development"
    "nwm-eval-mgr" = "20260730211204Z-development"
  }

  rds_instance_class        = "db.r7g.large"
  rds_allocated_storage_gib = 200
  redis_node_type           = "cache.r7g.large"
}
