# SIF staging (sif-sync): a one-off BOOTSTRAP task that seeds the shared EFS
# with the calibration workload .sif so jobs can run. A freshly created EFS is
# empty; this loads a standard, pinned .sif onto it ONCE at bring-up. It is a
# bootstrap concern, NOT a deploy/release one: Terraform creates the task here
# (existence); `make bootstrap` runs it once after `apply` (Twelve-Factor: a
# one-off admin process, kept out of `apply` per HashiCorp's "provisioners are
# a last resort").
# Rolling out a new .sif version later is a separate release process that re-runs
# this same task with a new pinned tag.
#
# Mechanism: a STANDALONE ECS task (RunTask, runs-to-completion, not a service)
# using the oras CLI (the standard OCI-artifact client) to pull
# ghcr.io/ngwpc/nwm-cal-mgr-sif:<tag> straight onto the EFS singularity access
# point, then repoint the stable nwm-cal-mgr.sif symlink. oras (not apptainer)
# because this only DOWNLOADS the artifact (the -sif package is a public oras
# artifact), so no container runtime needed inside the task. All gated on
# enable_pcs so NGWPC envs are untouched.
# SC-7: dedicated egress-only SG, private subnet. AC-6: minimal task role.

locals {
  # One generic staging command, reused by every per-workload task definition
  # (for_each below). Runs as `/bin/sh -c <this>` (the oras image entrypoint is
  # /bin/oras, overridden below). Bare $VARS are shell-expanded at container
  # runtime, NOT by Terraform (Terraform only interpolates ${...}); each task def
  # injects SIF_REPO / SIF_NAME / SIF_TAG per workload. The staging dir is
  # per-workload so concurrent runs can't collide. The symlink target is RELATIVE
  # so it also resolves under the compute node's mount path
  # (/ngencerf-app/singularity), not just this task's /mnt/singularity.
  sif_sync_command = <<-EOT
    set -eu
    dest=/mnt/singularity
    stage="$dest/.staging-$SIF_NAME"
    rm -rf "$stage"
    mkdir -p "$stage"
    echo "Pulling $SIF_REPO:$SIF_TAG onto EFS ..."
    oras pull "$SIF_REPO:$SIF_TAG" -o "$stage"
    sif=$(find "$stage" -name '*.sif' -type f | head -n1)
    if [ -z "$sif" ]; then echo "ERROR: no .sif file in artifact $SIF_REPO:$SIF_TAG" >&2; exit 1; fi
    final=$SIF_NAME-$SIF_TAG.sif
    mv -f "$sif" "$dest/$final"
    ln -sfn "$final" "$dest/$SIF_NAME.sif"
    rm -rf "$stage"
    echo "Staged $dest/$final"
    ls -l "$dest/$SIF_NAME.sif" "$dest/$final"
  EOT
}

resource "aws_cloudwatch_log_group" "sif_sync" {
  count             = var.enable_pcs ? 1 : 0
  name              = "/aws/ecs/${var.name_prefix}/sif-sync"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn
}

# Dedicated SG: egress to GHCR (via NAT); paired with the EFS ingress rule below
# to reach the shared filesystem. Egress-only, no inbound. SC-7.
resource "aws_security_group" "sif_sync" {
  count       = var.enable_pcs ? 1 : 0
  name        = "${var.name_prefix}-sif-sync-sg"
  description = "One-off SIF staging task: egress to GHCR, NFS to EFS."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "sif_sync_egress_all" {
  count             = var.enable_pcs ? 1 : 0
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sif_sync[0].id
  description       = "All egress (oras pull from GHCR via NAT)"
}

resource "aws_security_group_rule" "efs_ingress_sif_sync" {
  count                    = var.enable_pcs ? 1 : 0
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sif_sync[0].id
  security_group_id        = aws_security_group.efs.id
  description              = "NFS from the SIF staging task"
}

# Task role: mount the EFS access point (mirrors django_efs). The access point
# uses iam = DISABLED, so this is belt-and-suspenders, matching the Django EFS
# pattern. AC-6: scoped to the one EFS file system; no wildcards.
resource "aws_iam_role" "sif_sync_task" {
  count              = var.enable_pcs ? 1 : 0
  name               = "${var.name_prefix}-sif-sync-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "sif_sync_efs" {
  count = var.enable_pcs ? 1 : 0
  statement {
    effect = "Allow"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
    ]
    resources = [aws_efs_file_system.main.arn]
  }
}

resource "aws_iam_role_policy" "sif_sync_efs" {
  count  = var.enable_pcs ? 1 : 0
  name   = "efs-access"
  role   = aws_iam_role.sif_sync_task[0].name
  policy = data.aws_iam_policy_document.sif_sync_efs[0].json
}

# Standalone task definition, one per workload (for_each over var.sif_workloads).
# No service. Run on demand by `make bootstrap` (aws/scripts/bootstrap.sh).
# Reuses the shared ECS execution role (pulls the public oras image + writes
# logs; no secrets). Mounts only the singularity access point; writes as root
# (user 0) to the access-point root (owner 0/0), matching how the compute nodes
# write to the same EFS. each.key is the workload name (e.g. nwm-cal-mgr): both
# the GHCR repo base (<name>-sif) and the staged symlink (<name>.sif); each.value
# is the OCI tag.
resource "aws_ecs_task_definition" "sif_sync" {
  for_each                 = var.enable_pcs ? var.sif_workloads : {}
  family                   = "${var.name_prefix}-sif-sync-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.sif_sync_task[0].arn

  container_definitions = jsonencode([
    {
      name       = "sif-sync"
      image      = "ghcr.io/oras-project/oras:v1.3.2"
      essential  = true
      user       = "0"
      entryPoint = ["/bin/sh", "-c"]
      command    = [local.sif_sync_command]

      environment = [
        { name = "SIF_REPO", value = "ghcr.io/ngwpc/${each.key}-sif" },
        { name = "SIF_NAME", value = each.key },
        { name = "SIF_TAG", value = each.value },
        { name = "HOME", value = "/tmp" },
      ]

      mountPoints = [
        {
          sourceVolume  = "singularity"
          containerPath = "/mnt/singularity"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.sif_sync[0].name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "sif-sync-${each.key}"
        }
      }
    }
  ])

  volume {
    name = "singularity"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.singularity.id
        iam             = "DISABLED"
      }
    }
  }
}
