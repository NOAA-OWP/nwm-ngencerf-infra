# EC2 Image Builder: custom AMI for AWS PCS compute nodes.
#
# Bakes the compute-node software stack into one AMI so jobs start fast (no
# install-at-boot): the AWS PCS agent, Slurm 25.11 (matching the cluster), the
# Apptainer container runtime, and amazon-efs-utils (the EFS TLS mount helper).
# Apptainer container images (.sif) are NOT baked. They are staged on EFS and
# read at run time, so the AMI stays small and images update without a rebuild.
#
# Approach = AWS's documented production pattern: start from a clean Canonical
# Ubuntu 24.04 base and run AWS's own agent + Slurm installers, rather than
# customizing a PCS sample AMI. The PCS User Guide is explicit: "You must use
# AWS-provided installers to install the AWS PCS software on your custom AMI."
#
# Everything here is gated on var.build_compute_ami (default false), separate
# from var.enable_pcs: a build runs a ~20-30 min build instance, so it's an
# explicit opt-in. The compute node group consumes the result via
# var.pcs_compute_ami_id (see pcs.tf): build once, read the compute_ami_id
# output, pin it. NGWPC envs leave both off and are untouched.

locals {
  # Region-scoped base URL for the signed AWS PCS installer tarballs.
  pcs_installer_base = "https://aws-pcs-repo-${data.aws_region.current.name}.s3.${data.aws_region.current.name}.amazonaws.com"
}

# --- Base image (clean Ubuntu 24.04) ------------------------------------
# Canonical's official Ubuntu 24.04 LTS server AMI, resolved fresh on each build
# from Canonical's public SSM parameter so we always start from a patched base.

data "aws_ssm_parameter" "ubuntu_2404" {
  count = var.build_compute_ami ? 1 : 0
  name  = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# --- Build instance IAM -------------------------------------------------
# Image Builder drives a temporary EC2 "build" instance over SSM. That instance
# needs the Image Builder baseline (EC2InstanceProfileForImageBuilder) plus SSM
# core (AmazonSSMManagedInstanceCore). Image Builder itself uses the AWS-managed
# service-linked role (AWSServiceRoleForImageBuilder), so we don't define one.

data "aws_iam_policy_document" "imagebuilder_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "imagebuilder" {
  count              = var.build_compute_ami ? 1 : 0
  name               = "${var.name_prefix}-imagebuilder"
  assume_role_policy = data.aws_iam_policy_document.imagebuilder_assume.json
}

resource "aws_iam_role_policy_attachment" "imagebuilder_core" {
  count      = var.build_compute_ami ? 1 : 0
  role       = aws_iam_role.imagebuilder[0].name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

resource "aws_iam_role_policy_attachment" "imagebuilder_ssm" {
  count      = var.build_compute_ami ? 1 : 0
  role       = aws_iam_role.imagebuilder[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Same Session Manager logging policy the PCS nodes get, on the transient build
# instance's profile (it's an EC2 instance the Sandbox rules of the road cover).
# Always attached when an AMI build runs; the ARN is the account-scoped
# session_manager_logging_policy_arn local (see pcs.tf).
resource "aws_iam_role_policy_attachment" "imagebuilder_session_logging" {
  count      = var.build_compute_ami ? 1 : 0
  role       = aws_iam_role.imagebuilder[0].name
  policy_arn = local.session_manager_logging_policy_arn
}

resource "aws_iam_instance_profile" "imagebuilder" {
  count = var.build_compute_ami ? 1 : 0
  name  = "${var.name_prefix}-imagebuilder"
  role  = aws_iam_role.imagebuilder[0].name
}

# --- Build instance security group --------------------------------------
# The build instance only needs egress (download installers + .deb packages,
# git clone, reach SSM). No ingress, SSM connects outbound. SC-7.

resource "aws_security_group" "imagebuilder" {
  count       = var.build_compute_ami ? 1 : 0
  name        = "${var.name_prefix}-imagebuilder-sg"
  description = "EC2 Image Builder build instance (egress only)."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "imagebuilder_egress_all" {
  count             = var.build_compute_ami ? 1 : 0
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.imagebuilder[0].id
  description       = "All egress (installer downloads, package repos, SSM)"
}

# --- Image Builder component (the bake script) --------------------------
# One component, build phase, ordered ExecuteBash steps. The PCS agent + Slurm
# come from AWS's signed installer tarballs (verbatim from the PCS User Guide);
# Apptainer from its official non-suid .deb; amazon-efs-utils is built from
# source (no apt package on Ubuntu, it compiles a Rust efs-proxy, so we install
# a current Rust toolchain via rustup first). Slurm is pinned to 25.11 to match
# the cluster's scheduler version (the agent activates the matching build at
# boot). No reboot step: AWS's manual flow reboots after the OS upgrade, but a
# baked AMI's instances boot fresh on the upgraded kernel and nothing here needs
# the running kernel, so the reboot is unnecessary for the build.
#
# schemaVersion is written 1.0 (a YAML float) via a column-0 heredoc rather than
# yamlencode(), which would coerce 1.0 -> 1 and the CreateComponent API rejects
# that.

resource "aws_imagebuilder_component" "pcs_compute" {
  count    = var.build_compute_ami ? 1 : 0
  name     = "${var.name_prefix}-pcs-compute"
  platform = "Linux"
  version  = "1.0.4"

  data = <<EOT
name: ${var.name_prefix}-pcs-compute
description: PCS agent, Slurm 25.11, Apptainer, amazon-efs-utils.
schemaVersion: 1.0
phases:
  - name: build
    steps:
      - name: OsUpdate
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            - set -euxo pipefail
            - export DEBIAN_FRONTEND=noninteractive
            - apt-get update
            - apt-get upgrade -y
      - name: InstallPcsAgent
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            - set -euxo pipefail
            - cd /tmp
            - curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors ${local.pcs_installer_base}/aws-pcs-agent/aws-pcs-agent-v1.4.0-1.tar.gz -o aws-pcs-agent.tar.gz
            - tar -xf aws-pcs-agent.tar.gz
            - cd aws-pcs-agent
            - sudo ./installer.sh
            - cat /opt/aws/pcs/version || true
      - name: InstallSlurm
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            - set -euxo pipefail
            - cd /tmp
            - curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors ${local.pcs_installer_base}/aws-pcs-slurm/aws-pcs-slurm-25.11-installer-25.11.2-1.tar.gz -o aws-pcs-slurm.tar.gz
            - tar -xf aws-pcs-slurm.tar.gz
            - cd aws-pcs-slurm-25.11-installer
            - sudo ./installer.sh -y
            - cat /opt/aws/pcs/scheduler/slurm-25.11/version || true
      - name: InstallApptainer
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            - set -euxo pipefail
            - export DEBIAN_FRONTEND=noninteractive
            - cd /tmp
            - curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors https://github.com/apptainer/apptainer/releases/download/v1.5.0/apptainer_1.5.0_amd64.deb -o apptainer.deb
            - apt-get install -y ./apptainer.deb
            - apptainer --version
      - name: InstallEfsUtils
        action: ExecuteBash
        onFailure: Abort
        inputs:
          commands:
            - set -euxo pipefail
            - export HOME=/root
            - export DEBIAN_FRONTEND=noninteractive
            - apt-get update
            - apt-get install -y git binutils libssl-dev pkg-config gettext make gcc g++ cmake wget curl golang-go perl
            - curl --proto '=https' --tlsv1.2 -sSf --retry 5 --retry-delay 5 --retry-all-errors https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
            - . "$HOME/.cargo/env"
            - cd /tmp
            - for i in 1 2 3 4 5; do git clone https://github.com/aws/efs-utils && break || sleep 15; done
            - cd efs-utils
            - ./build-deb.sh
            - apt-get install -y ./build/amazon-efs-utils*deb
            - /sbin/mount.efs --version || true
EOT
}

# --- Image recipe -------------------------------------------------------
# Clean Ubuntu 24.04 parent + our one component. 50 GiB gp3 root so the Slurm
# compile and Rust toolchain have room; encrypted with the AWS-managed EBS key
# (SC-28: a customer-managed CMK is a hardening follow-up).

resource "aws_imagebuilder_image_recipe" "pcs_compute" {
  count        = var.build_compute_ami ? 1 : 0
  name         = "${var.name_prefix}-pcs-compute"
  version      = "1.0.4"
  parent_image = nonsensitive(data.aws_ssm_parameter.ubuntu_2404[0].value)

  component {
    component_arn = aws_imagebuilder_component.pcs_compute[0].arn
  }

  block_device_mapping {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
}

# --- Build infrastructure -----------------------------------------------
# Where the temporary build instance runs: a private subnet (NAT egress for the
# downloads + compile), the egress-only SG, the build instance profile. IMDSv2
# required. Terminate on failure so a bad build doesn't leave an instance up.

resource "aws_imagebuilder_infrastructure_configuration" "pcs_compute" {
  count                         = var.build_compute_ami ? 1 : 0
  name                          = "${var.name_prefix}-pcs-compute"
  instance_profile_name         = aws_iam_instance_profile.imagebuilder[0].name
  instance_types                = ["c6i.xlarge"]
  subnet_id                     = var.private_subnet_ids[0]
  security_group_ids            = [aws_security_group.imagebuilder[0].id]
  terminate_instance_on_failure = true

  # Tag the transient build instance: the Sandbox SCP enforces the Team tag on
  # instance creation, so an untagged build instance would fail to launch under it.
  resource_tags = var.tags

  instance_metadata_options {
    http_tokens = "required"
  }
}

# --- Distribution -------------------------------------------------------
# Register the output AMI in this region with a dated name + tags.

resource "aws_imagebuilder_distribution_configuration" "pcs_compute" {
  count = var.build_compute_ami ? 1 : 0
  name  = "${var.name_prefix}-pcs-compute"

  distribution {
    region = data.aws_region.current.name

    ami_distribution_configuration {
      name = "${var.name_prefix}-pcs-compute-{{ imagebuilder:buildDate }}"
      ami_tags = merge(var.tags, {
        Name = "${var.name_prefix}-pcs-compute"
        Role = "pcs-compute"
      })
    }
  }
}

# --- Image (triggers the build) -----------------------------------------
# Creating this resource runs the pipeline once and blocks apply until the AMI
# is registered. The test phase is skipped (no tests defined). The built AMI id
# is exposed as the compute_ami_id output; pin it into var.pcs_compute_ami_id to
# have the compute node group use it.

resource "aws_imagebuilder_image" "pcs_compute" {
  count                            = var.build_compute_ami ? 1 : 0
  image_recipe_arn                 = aws_imagebuilder_image_recipe.pcs_compute[0].arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.pcs_compute[0].arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.pcs_compute[0].arn

  image_tests_configuration {
    image_tests_enabled = false
  }
}
