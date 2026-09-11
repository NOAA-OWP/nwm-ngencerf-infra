# Django Fargate task + service. Image ghcr.io/ngwpc/ngencerf-server:latest is
# built from Dockerfile.production-pw. RDS CA bundle is baked into the image;
# all config is env-var-driven (no local_settings.py, settings.py reads
# everything via os.getenv). We only inject env vars + secrets here. EFS
# mounted at /ngencerf/data per the CONTAINER_DATA_ROOT constant in
# cerfServer/settings.py:300. assign_public_ip = false; egress via NAT.
# SC-7: data tier reachable only via web SG. AC-6: per-task IAM roles.

locals {
  # slurmrestd (Slurm REST API) endpoint the Django task POSTs jobs to.
  # PCS exposes one endpoint per Slurm daemon; select the SLURMRESTD one.
  pcs_slurmrestd_endpoint = var.enable_pcs ? one([
    for endpoint in awscc_pcs_cluster.main[0].endpoints : endpoint
    if endpoint.type == "SLURMRESTD"
  ]) : null
}

resource "aws_ecs_task_definition" "django" {
  family                   = "${var.name_prefix}-django"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.django_cpu
  memory                   = var.django_memory

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.django_task.arn

  container_definitions = jsonencode([
    {
      name      = "django"
      image     = var.ngencerf_server_image
      essential = true

      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]

      environment = concat(
        [
          { name = "DJANGO_DEBUG", value = "False" },
          { name = "CERF_ASGI", value = "1" },
          { name = "CERF_PRODUCTION", value = "1" },
          { name = "ALLOWED_HOSTS", value = join(",", concat([module.alb.dns_name], var.allowed_hosts)) },
          { name = "JOB_EXECUTION_MODE", value = var.enable_pcs ? "SLURM" : "DOCKER" },
          { name = "GUNICORN_WORKERS", value = "24" },
          { name = "GUNICORN_MAX_REQUESTS", value = "300" },
          { name = "GUNICORN_MAX_REQUESTS_JITTER", value = "100" },
          { name = "GUNICORN_GRACEFUL_TIMEOUT", value = "120" },
          { name = "CERF_SERVER_DATABASE_NAME", value = "ngencerf" },
          { name = "CERF_SERVER_DATABASE_USER", value = "ngencerf" },
          { name = "CERF_SERVER_DATABASE_HOST", value = module.rds.db_instance_address },
          { name = "REDIS_URL", value = "rediss://${aws_elasticache_replication_group.main.primary_endpoint_address}:6379/1" },

          # ngenCerf archive + zip storage in S3 (shared buckets in the Data
          # account). The server writes archived run directories under
          # NGENCERF_ARCHIVE_S3_PATH and downloadable run zips under
          # NGENCERF_ZIPS_S3_PATH (cloud_util.py reads both via the Django task
          # role). Each env sets its own prefix (env main.tf). S3 has no real
          # directories: a prefix exists only once an object is under it, so seed
          # a .keep object in each prefix before the first archive or zip write.
          { name = "NGENCERF_ARCHIVE_S3_PATH", value = var.ngencerf_archive_s3_path },
          { name = "NGENCERF_ZIPS_S3_PATH", value = var.ngencerf_zips_s3_path },

          # EDFS (NOAA Enterprise Data Services): at gage-create time (save_gage_tab)
          # the server fetches hydrofabric geopackages, observational streamflow, and
          # module-parameter metadata from here. settings.py reads both with os.getenv
          # and NO default, so unset makes the server raise
          # ValueError("Invalid environment: 'None'") before any fetch. ENTERPRISE_DATA_ENV
          # ('test'/'oe') also selects which EDFS host the MSWM client calls. The host is
          # private NOAA infra with no public DNS record, so the VPC needs a resolver path.
          { name = "ENTERPRISE_DATA_URL", value = var.enterprise_data_url },
          { name = "ENTERPRISE_DATA_ENV", value = var.enterprise_data_env },
        ],

        var.enable_pcs ? [
          # Slurm REST API: Django POSTs jobs to slurmrestd on the PCS
          # controller. JOB_EXECUTION_MODE flips to SLURM with the REST-adapter
          # image. NGENCERF_BASE_URL is the base for the callbacks the compute
          # job makes back to Django. get_callback_url()
          # (calibration/run_util/job_executor_slurm.py) builds NGENCERF_BASE_URL +
          # a callback path whose literals are BARE (no /api), as of the server's
          # "Update base endpoints" change, so the /api must live here in the base
          # or the callback 404s against the /api-prefixed routes. Keep the
          # explicit :80 (normalize_base_url appends :8000 otherwise). The Nuxt UI
          # base in nuxt.tf carries /api the same way.
          { name = "NGENCERF_BASE_URL", value = "http://${module.alb.dns_name}:80/api" },

          # NGENCERF_UI_URL: where the Django task reaches the running Nuxt UI. In
          # SLURM mode the Fargate task cannot inspect the UI container over Docker
          # (Fargate exposes no Docker daemon), so git_util.py HTTP-GETs the UI's
          # build-time git-info file from this URL (settings.py derives
          # NGENCERF_UI_GIT_INFO_URL = NGENCERF_UI_URL + /ngencerf-ui_git_info.json).
          # Point it at the ALB default route (anything not /api/* -> the Nuxt
          # target group): no /api prefix, and no :80 needed because http defaults
          # to port 80, which is the ALB listener (this value also skips
          # normalize_base_url, so nothing appends :8000). Set on its own, not
          # derived from NGENCERF_BASE_URL, so the UI and API can move to different
          # hosts or ports independently.
          { name = "NGENCERF_UI_URL", value = "http://${module.alb.dns_name}" },
          { name = "SLURM_REST_ENDPOINT", value = "http://${local.pcs_slurmrestd_endpoint.private_ip_address}:${local.pcs_slurmrestd_endpoint.port}" },
          { name = "SLURM_JWT_SECRET_ARN", value = awscc_pcs_cluster.main[0].slurm_configuration.auth_key.secret_arn },
          { name = "SLURM_API_VERSION", value = "v0.0.43" },
          { name = "SLURM_REST_USER", value = "root" },
          { name = "SLURM_REST_UID", value = "0" },
          { name = "SLURM_REST_GID", value = "0" },
          { name = "SLURM_REST_JOB_ENVIRONMENT", value = jsonencode(["PATH=/opt/aws/pcs/scheduler/slurm-25.11/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root"]) },

          # MPI_NODE_RULES overrides the server default of the same name
          # (cerfServer/settings.py): ordered [max_catchments, cpus] pairs that
          # map a run's catchment count to the job's CPU request. The server
          # recomputes this on every submission and writes the same value into
          # the model's parallel rank count, so the two always move together.
          # The single change from the server default is the 251-500 catchment
          # band at 5 CPUs instead of 6: the cluster reserves DefMemPerCPU
          # (17600 MB, pcs.tf) per requested CPU, and 6 x 17600 = 105600 MB
          # exceeds the c5n.9xlarge partition's 93388 MB nodes, so slurmrestd
          # rejects the submission outright ("Requested node configuration is
          # not available"), while 5 x 17600 = 88000 MB fits. Remove this
          # override once the server submits explicit per-job memory requests,
          # which decouples the CPU count from the per-CPU default reservation.
          { name = "MPI_NODE_RULES", value = "[[15, 1], [50, 2], [250, 4], [500, 5], [1000, 10], [1500, 12], [-1, 18]]" },

          # Host (compute-node) paths the Slurm adapter translates container paths
          # into. Jobs run on a compute node where the EFS root is mounted at
          # /ngencerf-app (pcs.tf launch template). HOST_DATA_ROOT is the
          # translation target (job_executor_slurm.py:
          # input_file.replace(CONTAINER_DATA_ROOT, HOST_DATA_ROOT)) and the host
          # side of the singularity bind-mount. The three SIF paths map to the
          # server's per-job-type singularity commands (settings.py
          # SINGULARITY_RUNTIME_INFO): cal-mgr runs calibration/validation,
          # fcst-mgr runs cold_start/forecast/hindcast, and nwm-eval-mgr (the
          # NWM_EVAL_* var; replaced nwm-verf) runs verification. Each points at
          # the stable symlink sif_sync.tf maintains so SIF swaps never touch
          # Django. All are os.getenv with NO default in settings.py, so an unset
          # one bakes the literal "None" into that job type's singularity command
          # and breaks its runs.
          { name = "HOST_DATA_ROOT", value = "/ngencerf-app/data/ngen-cal-data" },
          { name = "NWM_CAL_MGR_SINGULARITY_CONTAINER_PATH", value = "/ngencerf-app/singularity/nwm-cal-mgr.sif" },
          { name = "NWM_FCST_MGR_SINGULARITY_CONTAINER_PATH", value = "/ngencerf-app/singularity/nwm-fcst-mgr.sif" },
          { name = "NWM_EVAL_SINGULARITY_CONTAINER_PATH", value = "/ngencerf-app/singularity/nwm-eval-mgr.sif" },
        ] : [],

        var.enable_active_directory ? [
          # Active Directory / LDAP auth. settings.py reads these via os.getenv;
          # ACTIVE_DIRECTORY_ENABLED gates the whole feature. The bind PASSWORD is
          # NOT here, it is injected from Secrets Manager via the secrets block
          # below. LDAP_USER_SEARCH_BASE_DN + LDAP_DOMAIN fall back to the image
          # defaults (DC=nextgenwaterprediction,DC=com). Only set when enabled.
          { name = "ACTIVE_DIRECTORY_ENABLED", value = "true" },
          { name = "LDAP_SERVER_URI", value = var.ldap_server_uri },
          { name = "LDAP_SYSTEM_NAME", value = var.ldap_system_name },
          { name = "LDAP_BIND_DN", value = var.ldap_bind_dn },
          { name = "LDAP_USE_SSL", value = var.ldap_use_ssl ? "true" : "false" },
        ] : [],

        var.enable_mfa ? [
          # Mandatory MFA. settings.py reads this as
          # os.getenv("MFA_ENABLED", "false").lower() == "true", so the literal
          # "true" is what turns it on; when the flag is off the var is omitted
          # entirely and the server falls back to its own "false" default. The
          # server enforces MFA after the password check (its login view), so it
          # covers AD-backed users too: each user is forced to enroll an
          # authenticator app on next login and is issued recovery codes. That
          # enrollment lives in the database, so destroying an env's RDS wipes it
          # and every user re-enrolls on the next bring-up.
          { name = "MFA_ENABLED", value = "true" },
        ] : [],

        # Public-edge settings, only when this env is served through the
        # centralized public HTTPS edge (public ALB + NLB in front of this
        # env's internal ALB). CSRF_TRUSTED_ORIGINS lets Django accept
        # state-changing requests arriving from the public https origin;
        # TRUST_X_FORWARDED_PROTO makes Django honor the edge's
        # X-Forwarded-Proto header so redirects and absolute URLs keep the
        # https scheme. Both are env-driven server knobs, inert when unset.
        var.public_url != "" ? [
          { name = "CSRF_TRUSTED_ORIGINS", value = var.public_url },
          { name = "TRUST_X_FORWARDED_PROTO", value = "true" },
        ] : []
      )

      # LDAP bind password comes from the "password" key of the existing external
      # secret (data.aws_secretsmanager_secret.ldap_bind, secrets.tf). The for
      # expression yields one entry when AD is enabled (count 1) and none when
      # off, so the value is never read by Terraform and never enters state; ECS
      # pulls it straight from Secrets Manager at task start.
      secrets = concat(
        [
          { name = "CERF_SERVER_DATABASE_PASSWORD", valueFrom = aws_secretsmanager_secret.db.arn },
          { name = "CERF_SERVER_SECRET_KEY", valueFrom = aws_secretsmanager_secret.django_secret_key.arn },
        ],
        [
          for s in data.aws_secretsmanager_secret.ldap_bind : {
            name      = "LDAP_BIND_PASSWORD"
            valueFrom = "${s.arn}:password::"
          }
        ]
      )

      mountPoints = [
        {
          sourceVolume  = "data"
          containerPath = "/ngencerf/data"
          readOnly      = false
        },
        {
          sourceVolume  = "containers"
          containerPath = "/ngencerf/containers"
          readOnly      = false
        },
        {
          # runCerf flag dir, EFS-backed so the init_gages markers persist across
          # restarts (see efs.tf init_flags; the env var is baked + not overridable).
          sourceVolume  = "init_flags"
          containerPath = "/ngencerf/ngencerf-server/.init"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.django.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "django"
        }
      }
    }
  ])

  # Three EFS volumes via access points (efs.tf). The access point's root_directory
  # makes Django see an EFS subtree as /ngencerf/data + /ngencerf/containers + the
  # runCerf flag dir (PW-parity layout). transit_encryption is required with an
  # iam = DISABLED because the access point + EFS SG + the django_efs ClientMount
  # policy already gate access (no per-access-point IAM enforcement).
  volume {
    name = "data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.cal_data.id
        iam             = "DISABLED"
      }
    }
  }

  volume {
    name = "containers"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.singularity.id
        iam             = "DISABLED"
      }
    }
  }

  volume {
    name = "init_flags"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.init_flags.id
        iam             = "DISABLED"
      }
    }
  }
}

resource "aws_ecs_service" "django" {
  name                   = "${var.name_prefix}-django"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.django.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.web.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = module.alb.target_groups["django"].arn
    container_name   = "django"
    container_port   = 8000
  }

  health_check_grace_period_seconds  = 600
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  depends_on = [aws_efs_mount_target.main]
}
