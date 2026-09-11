# Nuxt UI Fargate task + service. Image ghcr.io/ngwpc/ngencerf-ui:latest is
# built from Dockerfile.production-pw: Nuxt 3 SSR bundle served by
# `npm run start` on port 3000 (image already sets NUXT_HOST=0.0.0.0 +
# NUXT_PORT=3000 and EXPOSE 3000). Stateless tier: no EFS, no DB, no secrets.
# NGENCERF_BASE_URL is read at runtime via nuxt.config.ts runtimeConfig.public
# (process.env.NGENCERF_BASE_URL -> useRuntimeConfig().public.ngencerfBaseUrl)
# so the same image can target any backend by setting that env var.
# SC-7: private subnet, reachable only through the ALB.
# AC-6: minimal task role. UI has no AWS API surface, so nuxt_task is empty.

resource "aws_ecs_task_definition" "nuxt" {
  family                   = "${var.name_prefix}-nuxt"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.nuxt_cpu
  memory                   = var.nuxt_memory

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.nuxt_task.arn

  container_definitions = jsonencode([
    {
      name      = "nuxt"
      image     = var.ngencerf_ui_image
      essential = true

      portMappings = [
        {
          containerPort = 3000
          protocol      = "tcp"
        }
      ]

      environment = [
        # Nuxt 3 auto-overrides runtimeConfig.public.ngencerfBaseUrl at runtime
        # only when the env var is named NUXT_PUBLIC_<KEY> (the un-prefixed
        # NGENCERF_BASE_URL in nuxt.config.ts is the BUILD-time default only).
        # Value /api routes through ALB rule /api/* -> Django. Public envs
        # (public_url set) hand the browser the public https origin instead of
        # the internal ALB DNS, which the browser cannot reach.
        { name = "NUXT_PUBLIC_NGENCERF_BASE_URL", value = var.public_url != "" ? "${var.public_url}/api" : "http://${module.alb.dns_name}/api" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.nuxt.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "nuxt"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "nuxt" {
  name                   = "${var.name_prefix}-nuxt"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.nuxt.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.web.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = module.alb.target_groups["nuxt"].arn
    container_name   = "nuxt"
    container_port   = 3000
  }

  health_check_grace_period_seconds  = 120
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
}
