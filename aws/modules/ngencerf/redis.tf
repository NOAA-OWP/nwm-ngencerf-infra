# ElastiCache Redis for Django session/cache backend.
# Replication-group API even for single-node, keeps the upgrade path to
# multi-node prod clean. SC-28: at-rest with env CMK. SC-13: in-transit TLS.
# AC-6: SG-locked to web tier (redis_ingress_web in security_groups.tf).
# Native Redis snapshots in prod; no AWS Backup tag (cache, not system-of-record).

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name_prefix}-redis"
  subnet_ids = var.private_subnet_ids
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "ngencerf Redis cache"

  engine               = "redis"
  engine_version       = "7.1"
  parameter_group_name = "default.redis7"

  node_type = var.redis_node_type
  port      = 6379

  # Single node in dev; primary + 1 replica in prod (failover requires 2+).
  num_cache_clusters         = var.production ? 2 : 1
  automatic_failover_enabled = var.production
  multi_az_enabled           = var.production

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = aws_kms_key.main.arn
  # No auth_token: TLS-encrypted in private subnets, SG-locked to web tier.

  snapshot_retention_limit = var.production ? 7 : 0
  snapshot_window          = "02:00-03:00"

  apply_immediately = !var.production

  tags = {
    Name = "${var.name_prefix}-redis"
  }
}
