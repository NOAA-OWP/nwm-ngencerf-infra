# IAM roles for ngencerf services.
#
# All roles, trust policies, and permissions live in this file (HashiCorp
# Style Guide logical-group split). Each role gets:
#   - aws_iam_role with assume_role_policy (who can assume it)
#   - aws_iam_role_policy_attachment for AWS-managed policies (boilerplate)
#   - aws_iam_role_policy for custom least-privilege permissions (inline)

# --- Trust policy documents -------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "step_functions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# --- ECS task execution role ------------------------------------------
# What ECS itself needs: pull image, write logs, fetch secrets.

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.name_prefix}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- Django task role -------------------------------------------------
# What the Django app code is allowed to do at runtime. Scoped permissions
# (S3, RDS, CW Logs) attach below.

resource "aws_iam_role" "django_task" {
  name               = "${var.name_prefix}-django-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# --- Step Functions execution role ------------------------------------
# Used by Step Functions state machines.

resource "aws_iam_role" "step_functions" {
  name               = "${var.name_prefix}-step-functions-role"
  assume_role_policy = data.aws_iam_policy_document.step_functions_assume.json
}

# --- Lambda helper role -----------------------------------------------
# Used by helper Lambdas invoked from Step Functions.

resource "aws_iam_role" "lambda_helper" {
  name               = "${var.name_prefix}-lambda-helper-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# --- ECS task execution: fetch secrets at task start ------------------
# AmazonECSTaskExecutionRolePolicy doesn't grant secretsmanager:GetSecretValue
# or kms:Decrypt for customer-managed CMKs. Add explicitly, scoped to the app
# secrets (DB + Django key on our CMK, plus the external LDAP bind secret when
# AD is enabled) and the secrets CMK. The LDAP secret uses the AWS-managed
# aws/secretsmanager key, which authorizes decrypt via GetSecretValue, so it
# needs no CMK grant. The for expression adds its ARN only when AD is enabled.

data "aws_iam_policy_document" "ecs_task_execution_secrets" {
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = concat([
      aws_secretsmanager_secret.db.arn,
      aws_secretsmanager_secret.django_secret_key.arn,
    ], [for s in data.aws_secretsmanager_secret.ldap_bind : s.arn])
  }
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name   = "secrets-access"
  role   = aws_iam_role.ecs_task_execution.name
  policy = data.aws_iam_policy_document.ecs_task_execution_secrets.json
}

# --- Django task: scoped S3 access on existing NGWPC buckets ----------
# AC-6: scoped to specific bucket ARNs, no s3:* wildcards.
# Buckets ngwpc-ngencerf-zips and ngwpc-ngencerf-archive live in NGWPC's
# Data account, owned by NGWPC infra, not by this stack. The
# cross-account access pattern (bucket policy vs role assumption) is set
# on the bucket side; this policy grants the IAM half on the consumer side.
#
# The buckets are encrypted by a CMK in the Data account. Cross-account
# kms:Decrypt + kms:GenerateDataKey must target that account's key ARN,
# not aws_kms_key.main here. Wire a `kms` statement to the Data-account
# CMK ARN at handoff.

data "aws_iam_policy_document" "django_s3" {
  statement {
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      "arn:aws:s3:::ngwpc-ngencerf-zips",
      "arn:aws:s3:::ngwpc-ngencerf-archive",
    ]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:aws:s3:::ngwpc-ngencerf-zips/*",
      "arn:aws:s3:::ngwpc-ngencerf-archive/*",
    ]
  }

  # Read-only on ngwpc-forcing (Data account). The data-assimilation engine
  # reads SNODAS / SMAP / SNOTEL observation CSVs from s3://ngwpc-forcing/
  # (snodas_csv, smap_csv, snotel_csv) at validation time. Read-only: the
  # engine never writes here. Same consumer-side IAM half as above; the
  # bucket-side grant is set on the Data account.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::ngwpc-forcing"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::ngwpc-forcing/*"]
  }

  # Read-only on ngwpc-dev nwm-tools-data (Data account). The server's
  # observation-data reads are moving from ngwpc-forcing to ngwpc-dev; the
  # forcing statements above are kept during the transition and get removed
  # once the ngwpc-dev path is the only one in use. GetObject is scoped to the
  # nwm-tools-data prefix to match the Data-side bucket-policy grant (which is
  # prefix-conditioned, not bucket-wide); widen both halves together if the
  # server's data lands under a different prefix.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::ngwpc-dev"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::ngwpc-dev/nwm-tools-data/*"]
  }
}

resource "aws_iam_role_policy" "django_s3" {
  name   = "s3-access"
  role   = aws_iam_role.django_task.name
  policy = data.aws_iam_policy_document.django_s3.json
}

# --- Django task: EFS mount permissions -------------------------------
# Fargate tasks mounting EFS need elasticfilesystem:ClientMount + ClientWrite
# granted via IAM on the task role (in addition to SG ingress to EFS:2049).
# Scoped to the env-specific EFS file system ARN.
# AC-6: scoped to a specific EFS file system; no wildcards.

data "aws_iam_policy_document" "django_efs" {
  statement {
    effect = "Allow"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
    ]
    resources = [aws_efs_file_system.main.arn]
  }
}

resource "aws_iam_role_policy" "django_efs" {
  name   = "efs-access"
  role   = aws_iam_role.django_task.name
  policy = data.aws_iam_policy_document.django_efs.json
}

# --- Django task: ECS Exec (ssmmessages) ------------------------------
# Required for `aws ecs execute-command` (interactive shell into a running
# task for ops debugging). ssmmessages doesn't support resource-level
# scoping per AWS IAM docs, so Resource: "*" is correct.
# AC-6: only the django_task role gets exec; AU-2: ECS CloudTrails the
# ExecuteCommand API call.

data "aws_iam_policy_document" "django_exec" {
  statement {
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "django_exec" {
  name   = "exec-command"
  role   = aws_iam_role.django_task.name
  policy = data.aws_iam_policy_document.django_exec.json
}

# --- Nuxt task role ---------------------------------------------------
# UI container is pure HTTP: renders pages, proxies API calls to Django
# via the ALB. No AWS SDK usage, no S3, no Secrets Manager, no DB. Empty
# role for correctness (ECS requires a task role on every task def).
# AC-6: minimal surface; future AWS integrations would scope here.

resource "aws_iam_role" "nuxt_task" {
  name               = "${var.name_prefix}-nuxt-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# --- Nuxt task: ECS Exec (reuses django_exec policy doc) --------------
# Same four ssmmessages channel actions. Reuses the django_exec data doc
# above since the ssmmessages permission shape is identical across tasks.
# AC-6: only nuxt_task gets exec capability for the UI tier.

resource "aws_iam_role_policy" "nuxt_exec" {
  name   = "exec-command"
  role   = aws_iam_role.nuxt_task.name
  policy = data.aws_iam_policy_document.django_exec.json
}
