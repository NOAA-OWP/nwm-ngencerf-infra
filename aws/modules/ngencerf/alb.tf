# Application Load Balancer fronting the Django Fargate service. Internet-facing
# by default; internal (on private subnets) when var.alb_internal = true.
# HTTP-only on port 80; HTTPS + ACM via terraform-aws-acm-cross-account
# lands later. Listener rule /api/* -> Django target group; default action
# forwards to the Nuxt UI target group. idle_timeout = 240 covers the
# CLI's ZIP download path. SG attached is aws_security_group.alb (declared
# in security_groups.tf); deletion_protection = var.production keeps prod
# from accidental destroys.
# SC-7: boundary protection at the perimeter. AC-3: path-based routing.
# target_type = ip is required for Fargate. create_attachment = false on
# the target group because the ECS service registers/deregisters tasks.

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name     = "${var.name_prefix}-alb"
  vpc_id   = var.vpc_id
  internal = var.alb_internal
  subnets  = var.alb_internal ? var.private_subnet_ids : var.public_subnet_ids

  enable_deletion_protection = var.production
  idle_timeout               = 240

  create_security_group = false
  security_groups       = [aws_security_group.alb.id]

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = "nuxt"
      }

      rules = {
        api = {
          priority = 100

          actions = [{
            type             = "forward"
            target_group_key = "django"
          }]

          conditions = [{
            path_pattern = {
              values = ["/api/*"]
            }
          }]
        }
      }
    }
  }

  target_groups = {
    django = {
      name              = "${var.name_prefix}-django"
      protocol          = "HTTP"
      port              = 8000
      target_type       = "ip"
      create_attachment = false

      # Django liveness probe. Path is /api/health_check/ (the route is
      # mounted under the /api prefix). matcher = "200" requires a true 200,
      # so a DisallowedHost 400 no longer passes as healthy. The Fargate task
      # adds its own private IP to ALLOWED_HOSTS at startup, so this probe
      # clears Django host validation.
      health_check = {
        enabled             = true
        path                = "/api/health_check/"
        port                = "traffic-port"
        protocol            = "HTTP"
        matcher             = "200"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 3
      }
    }

    nuxt = {
      name              = "${var.name_prefix}-nuxt"
      protocol          = "HTTP"
      port              = 3000
      target_type       = "ip"
      create_attachment = false

      health_check = {
        enabled             = true
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        matcher             = "200-499"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 3
      }
    }
  }
}
