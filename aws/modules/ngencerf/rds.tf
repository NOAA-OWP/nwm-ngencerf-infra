# RDS Postgres for ngencerf application data (job queue, calibration metadata).
# terraform-aws-modules/rds/aws ~> 6.0 wraps the ~6 separate resources RDS
# needs (instance, subnet group, parameter group, etc.), the community standard.
# SC-28: storage encrypted with env-wide CMK. CP-9: BackupPlan: Daily tag for
# LZA backup vault. AC-6: SG-locked to web tier only (db_ingress_web).

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "${var.name_prefix}-db"

  engine               = "postgres"
  engine_version       = "16.14"
  family               = "postgres16"
  major_engine_version = "16"
  instance_class       = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage_gib
  max_allocated_storage = var.rds_allocated_storage_gib * 5 # autoscale ceiling
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  db_name  = "ngencerf"
  username = "ngencerf"
  password = aws_secretsmanager_secret_version.db.secret_string
  port     = 5432

  manage_master_user_password = false

  multi_az               = var.production
  create_db_subnet_group = true
  subnet_ids             = var.private_subnet_ids
  vpc_security_group_ids = [aws_security_group.db.id]

  backup_retention_period = var.production ? 30 : 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  deletion_protection = var.production
  skip_final_snapshot = !var.production
  apply_immediately   = !var.production

  performance_insights_enabled          = var.production
  performance_insights_retention_period = var.production ? 7 : 0
  monitoring_interval                   = var.production ? 60 : 0
  # Auto-create the role, but give it a unique name to avoid account-wide collisions
  create_monitoring_role = var.production
  monitoring_role_name   = "${var.name_prefix}-rds-monitoring"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = {
    BackupPlan = "Daily"
  }
}
