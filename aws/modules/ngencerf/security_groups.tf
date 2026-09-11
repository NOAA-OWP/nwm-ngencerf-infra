# Security groups (stateful firewalls).
# Pattern: SGs reference each other by ID; CIDRs only at the internet edge.
# Convention: aws_security_group_rule attachment resources, not inline ingress/egress.

# --- ALB ---------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Application Load Balancer; ingress from internet."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from internet. HTTPS listener added once ACM cert is wired."
}

resource "aws_security_group_rule" "alb_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
  description       = "All egress"
}

# --- Web tier (Django Fargate tasks) -----------------------------------

resource "aws_security_group" "web" {
  name        = "${var.name_prefix}-web-sg"
  description = "Django + UI ECS Fargate tasks."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "web_ingress_alb" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.web.id
  description              = "Django from ALB"
}

resource "aws_security_group_rule" "web_ingress_alb_nuxt" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.web.id
  description              = "Nuxt UI from ALB"
}

resource "aws_security_group_rule" "web_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.web.id
  description       = "All egress"
}

# --- RDS Postgres ------------------------------------------------------

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "RDS Postgres."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "db_ingress_web" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.web.id
  security_group_id        = aws_security_group.db.id
  description              = "Postgres from web"
}

# Optional extra CIDRs (var.db_ingress_cidrs, empty by default) allowed to
# reach Postgres directly, e.g. developer/operator access from team WorkSpaces.
resource "aws_security_group_rule" "db_ingress_extra" {
  for_each          = toset(var.db_ingress_cidrs)
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = [each.value]
  security_group_id = aws_security_group.db.id
  description       = "Postgres from ${each.value}"
}

# --- ElastiCache Redis -------------------------------------------------

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis-sg"
  description = "ElastiCache Redis."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "redis_ingress_web" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.web.id
  security_group_id        = aws_security_group.redis.id
  description              = "Redis from web"
}

# --- EFS ---------------------------------------------------------------

resource "aws_security_group" "efs" {
  name        = "${var.name_prefix}-efs-sg"
  description = "EFS shared filesystem."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "efs_ingress_web" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.web.id
  security_group_id        = aws_security_group.efs.id
  description              = "NFS from web"
}
