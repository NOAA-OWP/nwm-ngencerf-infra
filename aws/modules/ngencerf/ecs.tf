# ECS Fargate cluster. The cluster itself is free; cost lives in the tasks
# that run inside it. Container Insights enables per-task CPU/memory/network
# metrics in CloudWatch (~$0.50/task/month). Task definitions + services
# land in their own per-service files (e.g., django.tf).

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
