# AWS PCS (Parallel Computing Service): managed Slurm.
#
# PCS resources live in the `awscc` (AWS Cloud Control) provider, NOT the
# classic `aws` provider. The `aws` provider has no PCS resources. `awscc` is AWS's
# auto-generated provider over the Cloud Control API; AWS officially blesses
# it for PCS Terraform. The two providers run side by side: the cluster,
# compute node groups, and queue come from `awscc`; the supporting IAM,
# security group, launch template, and AMI lookup stay in `aws`.
#
# Everything here is gated behind var.enable_pcs (default false). It is set
# true per env that runs PCS (sandbox today); non-PCS envs are untouched.
#
# Submission model = Slurm REST API: Django (on Fargate) POSTs jobs
# to slurmrestd on the controller (port 6820, JWT). The login node group below
# is kept as a testing/ops on-ramp (SSM in to drive Slurm by hand: verify
# scheduling, debug). It is NOT in the submission path; Django uses the REST
# API above.

# --- PCS node AMI -------------------------------------------------------
# AWS publishes PCS-ready sample AMIs as SSM public parameters. Verified in
# this account: only the Ubuntu 24.04 DLAMI-base flavor is published. The AMI
# bakes the PCS/Slurm agent, so a minimal cluster needs no user_data.

data "aws_ssm_parameter" "pcs_ami" {
  count = var.enable_pcs ? 1 : 0
  name  = "/aws/service/pcs/ami/dlami-base-ubuntu2404/x86_64/latest/ami-id"
}

# AMI for the two COMPUTE node groups (the login node always uses the sample AMI
# below, it runs no .sif workloads). Resolution order: an explicit pin wins;
# else the AMI just baked in-account by Image Builder (build_compute_ami), read
# straight from the resource so ONE apply builds AND uses it (no manual "read the
# output, pin it, re-apply" step); else "" so the node group falls back to the
# PCS sample AMI. The build re-runs only on first apply + image-recipe version
# bumps, so build_compute_ami can stay true permanently.
locals {
  pcs_compute_override_ami_id = var.pcs_compute_ami_id != "" ? var.pcs_compute_ami_id : (
    var.build_compute_ami ? one(aws_imagebuilder_image.pcs_compute[0].output_resources[0].amis[*].image) : ""
  )

  # The LZA-managed Session Manager logging policy, present in every NGWPC LZA
  # account. Attached to compute instance profiles (PCS nodes + the Image Builder
  # build instance) so SSM sessions log centrally, per the Sandbox rules of the road.
  session_manager_logging_policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/AWSAccelerator-SessionManagerLogging"
}

# --- PCS node IAM -------------------------------------------------------
# Compute + login instances register with the cluster and are managed over
# SSM (no SSH). The role NAME must start with "AWSPCS" (or use path
# /aws-pcs/), because PCS requires this prefix to recognize the instance profile.
# AC-6: pcs:RegisterComputeNodeGroupInstance is the only inline grant; SSM +
# CloudWatch come from AWS-managed policies.

data "aws_iam_policy_document" "pcs_node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "pcs_register" {
  statement {
    effect    = "Allow"
    actions   = ["pcs:RegisterComputeNodeGroupInstance"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "pcs_node" {
  count              = var.enable_pcs ? 1 : 0
  name               = "AWSPCS-${var.name_prefix}-node"
  assume_role_policy = data.aws_iam_policy_document.pcs_node_assume.json
}

resource "aws_iam_role_policy" "pcs_register" {
  count  = var.enable_pcs ? 1 : 0
  name   = "pcs-register-node"
  role   = aws_iam_role.pcs_node[0].id
  policy = data.aws_iam_policy_document.pcs_register.json
}

resource "aws_iam_role_policy_attachment" "pcs_node_ssm" {
  count      = var.enable_pcs ? 1 : 0
  role       = aws_iam_role.pcs_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "pcs_node_cloudwatch" {
  count      = var.enable_pcs ? 1 : 0
  role       = aws_iam_role.pcs_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Sandbox rules of the road require the LZA-managed Session Manager logging
# policy on every compute instance profile so SSM sessions are logged to the
# central destination. Always attached when PCS is enabled (no opt-out); the
# ARN is the account-scoped session_manager_logging_policy_arn local above, so
# it resolves to this account's AWSAccelerator-SessionManagerLogging policy.
# Assumes an LZA-governed account, which every NGWPC env this module targets is.
resource "aws_iam_role_policy_attachment" "pcs_node_session_logging" {
  count      = var.enable_pcs ? 1 : 0
  role       = aws_iam_role.pcs_node[0].name
  policy_arn = local.session_manager_logging_policy_arn
}

# Cross-account read on the Data-account ngwpc-dev bucket so the login node can
# sync the ngen static-input tree onto EFS at bootstrap (make bootstrap /
# make load-static run the load over SSM on the login node, which shares this
# node role). The Data side must also grant this role (bucket policy / assumable
# role) for the read to succeed. AC-6: read-only, scoped to the static prefixes.
data "aws_iam_policy_document" "pcs_node_static_data_s3" {
  count = var.enable_pcs ? 1 : 0
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::ngwpc-dev"]
  }
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::ngwpc-dev/nwm-tools-data/esmf/*",
      "arn:aws:s3:::ngwpc-dev/nwm-tools-data/nwm_retrospective/*",
    ]
  }
}

resource "aws_iam_role_policy" "pcs_node_static_data_s3" {
  count  = var.enable_pcs ? 1 : 0
  name   = "ngwpc-dev-static-read"
  role   = aws_iam_role.pcs_node[0].name
  policy = data.aws_iam_policy_document.pcs_node_static_data_s3[0].json
}

resource "aws_iam_instance_profile" "pcs_node" {
  count = var.enable_pcs ? 1 : 0
  name  = "AWSPCS-${var.name_prefix}-node"
  role  = aws_iam_role.pcs_node[0].name
}

# --- PCS security group -------------------------------------------------
# One SG for the cluster, compute, and login nodes. All-internal: members
# talk to each other on any port (Slurm control + MPI), egress open for SSM,
# package installs, and (later) Django REST callbacks. The slurmrestd:6820
# ingress from the web tier is added with the Slurm REST API wiring, not here.
# SC-7: no inbound from the internet.

resource "aws_security_group" "pcs" {
  count       = var.enable_pcs ? 1 : 0
  name        = "${var.name_prefix}-pcs-sg"
  description = "AWS PCS cluster, compute, and login nodes (all-internal)."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "pcs_ingress_self" {
  count             = var.enable_pcs ? 1 : 0
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.pcs[0].id
  description       = "All traffic between PCS nodes (Slurm control + MPI)"
}

resource "aws_security_group_rule" "pcs_egress_all" {
  count             = var.enable_pcs ? 1 : 0
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.pcs[0].id
  description       = "All egress (SSM, package installs, callbacks)"
}

# --- EFS reachability from PCS nodes ------------------------------------
# Opens 2049 (NFS) on the EFS SG to the PCS SG so compute + login nodes can
# mount the shared filesystem the launch template configures below. The EFS SG
# otherwise admits only the web tier (efs_ingress_web in security_groups.tf).
# Gated on enable_pcs because the PCS SG only exists then, and kept here (not in
# security_groups.tf) so tearing out PCS removes this with it (same pattern as
# pcs_ingress_web_slurmrestd).

resource "aws_security_group_rule" "efs_ingress_pcs" {
  count                    = var.enable_pcs ? 1 : 0
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.pcs[0].id
  security_group_id        = aws_security_group.efs.id
  description              = "NFS from PCS compute + login nodes"
}

# --- PCS node launch template -------------------------------------------
# Shared by the compute and login node groups. Carries the PCS SG, enforces
# IMDSv2, and mounts the shared EFS. Instance type is set per node group
# (instance_configs), not here. IMDSv2-only hardens the instance metadata
# endpoint against SSRF credential theft.

resource "aws_launch_template" "pcs" {
  count       = var.enable_pcs ? 1 : 0
  name        = "${var.name_prefix}-pcs-node"
  description = "PCS compute + login node settings: PCS SG, IMDSv2, EFS mount."

  vpc_security_group_ids = [aws_security_group.pcs[0].id]

  # Mount the shared EFS root at /ngencerf-app via cloud-init.
  #
  # PCS REQUIRES launch-template user_data to be a MIME multipart archive: it
  # merges its own node-bootstrap (Slurm agent registration) into your parts.
  # Plain shell-script user_data would replace that bootstrap and the node would
  # never join the cluster. The text/cloud-config part runs before the node
  # registers with the PCS API.
  #
  # amazon-efs-utils provides the `efs` mount type with `tls` (in-transit
  # encryption), matching the Django mount (transit_encryption = ENABLED in
  # django.tf). Compute nodes mount the EFS ROOT at /ngencerf-app (PW-parity
  # layout): SIFs land at /ngencerf-app/singularity, cal data at
  # /ngencerf-app/data/ngen-cal-data. Django (Fargate) mounts the SAME EFS via
  # access points at /ngencerf/data + /ngencerf/containers; the Slurm adapter
  # translates those container paths to these host paths (HOST_DATA_ROOT in
  # django.tf). Mounting by file-system-id (not DNS) lets the efs helper pick the
  # AZ-local mount target. SC-28: encryption in transit.
  #
  # Unattended-upgrades are disabled at boot. The Ubuntu base ships with
  # automatic background OS updates enabled, and their persistent apt timers
  # run a catch-up upgrade shortly after every node boot (the AMI's package
  # state is as old as its last bake). That upgrade can pull in
  # systemd/udev/networkd and restart the network stack while a job is
  # running; slurmd then goes silent past SlurmdTimeout and the controller
  # marks the node NODE_FAIL, killing its jobs, after which the node recovers.
  # These nodes are ephemeral and run a pinned AMI, so background patching
  # adds risk without benefit: OS updates are delivered by baking and pinning
  # a new AMI instead. write_files zeroes the APT::Periodic knobs early in
  # boot (the apt.systemd.daily script then exits without acting); runcmd
  # masks the apt-daily units as defense in depth.
  user_data = base64encode(<<EOT
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==MYBOUNDARY=="

--==MYBOUNDARY==
Content-Type: text/cloud-config; charset="us-ascii"

write_files:
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "0";
      APT::Periodic::Unattended-Upgrade "0";

packages:
  - amazon-efs-utils

runcmd:
  - systemctl mask --now apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service
  - mkdir -p /ngencerf-app
  - echo "${aws_efs_file_system.main.id}:/ /ngencerf-app efs tls,_netdev" >> /etc/fstab
  - mount -a -t efs defaults

--==MYBOUNDARY==--
EOT
  )

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # Tag the launched instances AND their EBS volumes explicitly: default_tags
  # don't reach instances/volumes created at runtime by PCS autoscaling, so the
  # common tag set (incl. the SCP-enforced Team tag) is merged in here.
  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name_prefix}-pcs-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name_prefix}-pcs-node" })
  }

  # GUARD: tag churn must never roll the compute node fleet. The node groups pin
  # latest_version of this template, and ANY content change here (even a change
  # to the tag VALUES fed into tag_specifications above) cuts a new version,
  # which PCS treats as a node-group update: it
  # drains and replaces every compute instance in the group.
  # Instance/volume tags are applied at creation; later drift in var.tags is
  # deliberately NOT propagated. To change instance tags for real, remove this
  # ignore temporarily and treat the apply as a deliberate fleet roll (PCS lets
  # running jobs finish, then replaces each node at idle).
  lifecycle {
    ignore_changes = [tag_specifications]
  }
}

# --- PCS cluster (awscc) ------------------------------------------------
# MEDIUM controller (handles up to 512 nodes / 8192 jobs; the 50-node-per-partition ceiling exceeds SMALL's 32-node cap), Slurm 25.11 (25.05 was the minimum that supports BOTH accounting
# and the Slurm REST API). accounting=STANDARD records job history (sacct) and
# is a prerequisite for slurmrestd. slurm_rest=STANDARD turns on slurmrestd
# (port 6820, JWT): the Django submission door. Idle compute scales down after
# 5 minutes.
#
# COST: the MEDIUM controller bills hourly even at 0 compute, and accounting
# adds a second hourly fee, NOT free. Destroy at end of day.

resource "awscc_pcs_cluster" "main" {
  count = var.enable_pcs ? 1 : 0
  name  = "${var.name_prefix}-pcs"
  size  = var.pcs_controller_size

  scheduler = {
    type    = "SLURM"
    version = "25.11"
  }

  networking = {
    subnet_ids         = [var.private_subnet_ids[0]]
    security_group_ids = [aws_security_group.pcs[0].id]
  }

  slurm_configuration = {
    accounting = {
      mode                       = "STANDARD"
      default_purge_time_in_days = 7
    }
    scale_down_idle_time_in_seconds = 300
    slurm_rest = {
      mode = "STANDARD"
    }

    # Memory-aware scheduling. Slurm's default SelectTypeParameters (CR_CPU)
    # counts only CPUs when packing jobs onto a node, so enough concurrent
    # jobs can oversubscribe the node's RAM and trigger the kernel OOM killer,
    # which kills jobs and can take the whole node (and every job on it) down.
    # CR_CPU_Memory makes memory a consumable resource the scheduler tracks.
    # DefMemPerCPU is the default reservation per CPU a job requests, applied
    # to every job that does not request memory explicitly (currently all of
    # them). 17600 MB is sized to the largest per-CPU memory footprint job
    # accounting has recorded (a single-CPU job peaking at 17.6 GB), which
    # deliberately over-reserves for lighter jobs and caps a 93 GB
    # c5n.9xlarge at ~5 concurrent jobs; overflow jobs scale out onto
    # additional nodes rather than oversubscribing one. Tighten this only by
    # moving to explicit per-job-type memory requests from the submitting
    # server, informed by accounting data. Both are AWS PCS cluster-level
    # custom Slurm settings (docs: "Custom Slurm settings for AWS PCS
    # clusters") and update in place, BUT per the GUARD below a cluster
    # update drains and replaces compute nodes, so apply only while the
    # queues are idle.
    slurm_custom_settings = [
      {
        parameter_name  = "SelectTypeParameters"
        parameter_value = "CR_CPU_Memory"
      },
      {
        parameter_name  = "DefMemPerCPU"
        parameter_value = "17600"
      },
    ]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-pcs" })

  # GUARD: same rationale as the launch template's lifecycle note above. An
  # update to this resource makes PCS run a "cluster update" that drains and
  # replaces compute nodes; resource-tag drift is not worth a fleet roll.
  lifecycle {
    ignore_changes = [tags]
  }

  # PCS reads this cluster's security group during CreateCluster and rejects an
  # SG with no outbound rules. The SG's egress and ingress are separate
  # aws_security_group_rule attachment resources, so without an explicit
  # dependency Terraform creates the cluster in parallel with them, a race that
  # intermittently fails with "At least one security group must have outbound
  # rules to allow outgoing traffic". Order the cluster after both rules so the
  # SG is fully configured before PCS validates it.
  depends_on = [
    aws_security_group_rule.pcs_egress_all,
    aws_security_group_rule.pcs_ingress_self,
  ]
}

# --- Compute node groups (awscc) ----------------------------------------
# Two groups, one per Slurm partition the server routes to. ngencerf-server
# picks the partition by catchment count: <=500 catchments -> the "default"
# group (c5n-9xlarge queue), >500 -> the "heavy" group (r8a-12xlarge queue).
# Jobs are single-node (the server emits --nodes=1 --ntasks=1 --cpus-per-task=N),
# so a group's instance type just has to carry the largest cpus-per-task that
# path requests (default <=6, heavy <=18). Both autoscale from min=0, so idle
# cost is $0, only the controller bills until a job lands. Instance type per
# group is operator-set (pcs_compute_*_instance_type); uniform prod sizing across
# all envs is c5n.9xlarge / r8a.12xlarge, max 50 nodes/partition.

resource "awscc_pcs_compute_node_group" "compute_default" {
  count      = var.enable_pcs ? 1 : 0
  name       = "compute-default"
  cluster_id = awscc_pcs_cluster.main[0].cluster_id
  ami_id     = local.pcs_compute_override_ami_id != "" ? local.pcs_compute_override_ami_id : nonsensitive(data.aws_ssm_parameter.pcs_ami[0].value)

  custom_launch_template = {
    template_id = aws_launch_template.pcs[0].id
    version     = tostring(aws_launch_template.pcs[0].latest_version)
  }

  iam_instance_profile_arn = aws_iam_instance_profile.pcs_node[0].arn

  instance_configs = [{
    instance_type = var.pcs_compute_default_instance_type
  }]

  scaling_configuration = {
    min_instance_count = 0
    max_instance_count = var.pcs_max_nodes_per_partition
  }

  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-compute-default" })

  # GUARD: see the launch-template lifecycle note; tag drift alone must not
  # trigger a node-group update (= drain + replace every node in the group).
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "awscc_pcs_compute_node_group" "compute_heavy" {
  count      = var.enable_pcs ? 1 : 0
  name       = "compute-heavy"
  cluster_id = awscc_pcs_cluster.main[0].cluster_id
  ami_id     = local.pcs_compute_override_ami_id != "" ? local.pcs_compute_override_ami_id : nonsensitive(data.aws_ssm_parameter.pcs_ami[0].value)

  custom_launch_template = {
    template_id = aws_launch_template.pcs[0].id
    version     = tostring(aws_launch_template.pcs[0].latest_version)
  }

  iam_instance_profile_arn = aws_iam_instance_profile.pcs_node[0].arn

  instance_configs = [{
    instance_type = var.pcs_compute_heavy_instance_type
  }]

  scaling_configuration = {
    min_instance_count = 0
    max_instance_count = var.pcs_max_nodes_per_partition
  }

  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-compute-heavy" })

  # GUARD: see the launch-template lifecycle note; tag drift alone must not
  # trigger a node-group update (= drain + replace every node in the group).
  lifecycle {
    ignore_changes = [tags]
  }
}

# --- Login node group (awscc) -------------------------------------------
# A single always-on node we SSM into to drive Slurm by hand
# (`sbatch`/`squeue`/`sacct`/`sinfo`). It is NOT attached to the queue, so the
# scheduler never places jobs on it, and it is NOT in the job-submission path:
# Django submits straight to the Slurm REST API (slurmrestd), never through this
# node. KEPT purely as a TESTING + ops on-ramp: a place to SSM in and inspect
# or drive Slurm directly (verify scheduling, debug job state, run a manual
# job). Nothing in the application depends on it; safe to remove if a standing
# ops box isn't wanted.

resource "awscc_pcs_compute_node_group" "login" {
  count      = var.enable_pcs ? 1 : 0
  name       = "login"
  cluster_id = awscc_pcs_cluster.main[0].cluster_id
  ami_id     = nonsensitive(data.aws_ssm_parameter.pcs_ami[0].value)

  custom_launch_template = {
    template_id = aws_launch_template.pcs[0].id
    version     = tostring(aws_launch_template.pcs[0].latest_version)
  }

  iam_instance_profile_arn = aws_iam_instance_profile.pcs_node[0].arn

  instance_configs = [{
    instance_type = "c6i.large"
  }]

  scaling_configuration = {
    min_instance_count = 1
    max_instance_count = 1
  }

  subnet_ids = [var.private_subnet_ids[0]]

  tags = merge(var.tags, { Name = "${var.name_prefix}-login" })

  # GUARD: see the launch-template lifecycle note; tag drift alone must not
  # trigger a node-group update (= drain + replace the login node).
  lifecycle {
    ignore_changes = [tags]
  }
}

# --- Queues (awscc) -----------------------------------------------------
# A PCS queue IS a Slurm partition. The server routes each job to a partition
# BY NAME and rejects any name it didn't emit, so these names must be EXACTLY
# "c5n-9xlarge" and "r8a-12xlarge" (hyphens, not dots). They are the partition
# identifiers in the server's SLURM_NODE_TYPE_RULES, not instance types. Each
# queue points at its backing compute node group (not login).
#
# Default partition: calibration + validation submit WITH an explicit partition,
# but forecast/hindcast/cold_start/verification submit with NONE, so Slurm needs
# a default partition for them. AWS PCS exposes Slurm's partition-level "Default"
# option as a queue-level custom Slurm setting; "Default = YES" makes c5n-9xlarge
# the partition Slurm uses when a job names none. Exactly one queue may be the
# default. Docs: AWS PCS "Custom Slurm settings for AWS PCS queues" (OPT_Default)
# + awscc_pcs_queue slurm_configuration.slurm_custom_settings.

resource "awscc_pcs_queue" "c5n_9xlarge" {
  count      = var.enable_pcs ? 1 : 0
  name       = "c5n-9xlarge"
  cluster_id = awscc_pcs_cluster.main[0].cluster_id

  compute_node_group_configurations = [{
    compute_node_group_id = awscc_pcs_compute_node_group.compute_default[0].compute_node_group_id
  }]

  slurm_configuration = {
    slurm_custom_settings = [{
      parameter_name  = "Default"
      parameter_value = "YES"
    }]
  }

  tags = var.tags

  # GUARD: see the launch-template lifecycle note.
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "awscc_pcs_queue" "r8a_12xlarge" {
  count      = var.enable_pcs ? 1 : 0
  name       = "r8a-12xlarge"
  cluster_id = awscc_pcs_cluster.main[0].cluster_id

  compute_node_group_configurations = [{
    compute_node_group_id = awscc_pcs_compute_node_group.compute_heavy[0].compute_node_group_id
  }]

  tags = var.tags

  # GUARD: see the launch-template lifecycle note.
  lifecycle {
    ignore_changes = [tags]
  }
}

# --- Slurm REST API wiring: Django (web tier) -> slurmrestd -------------
# Lets the Django Fargate task submit jobs to the cluster over the Slurm REST
# API (slurmrestd, port 6820). Part of the PCS feature, so gated on
# var.enable_pcs and kept here (removing PCS removes this too).

# slurmrestd:6820 ingress from the Django web SG. The web SG already has
# all-egress, so this inbound rule is the only opening needed.
# SC-7: still no path from the internet; only the web tier reaches the API.
resource "aws_security_group_rule" "pcs_ingress_web_slurmrestd" {
  count                    = var.enable_pcs ? 1 : 0
  type                     = "ingress"
  from_port                = 6820
  to_port                  = 6820
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.web.id
  security_group_id        = aws_security_group.pcs[0].id
  description              = "slurmrestd (Slurm REST API) from the Django web tier"
}

# Django signs a JWT with the cluster's JWT key to call slurmrestd. PCS keeps
# that key in a Secrets Manager secret it manages; grant the Django task role
# read access to exactly that secret.
# AC-6: scoped to the single PCS-managed auth-key secret ARN, no wildcards.
data "aws_iam_policy_document" "django_pcs_jwt_secret" {
  count = var.enable_pcs ? 1 : 0
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [awscc_pcs_cluster.main[0].slurm_configuration.auth_key.secret_arn]
  }
}

resource "aws_iam_role_policy" "django_pcs_jwt_secret" {
  count  = var.enable_pcs ? 1 : 0
  name   = "pcs-slurm-jwt-secret"
  role   = aws_iam_role.django_task.name
  policy = data.aws_iam_policy_document.django_pcs_jwt_secret[0].json
}
