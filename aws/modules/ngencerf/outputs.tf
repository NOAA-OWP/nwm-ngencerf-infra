output "alb_arn" {
  value       = module.alb.arn
  description = "ALB ARN. Consumed by aws_wafv2_web_acl_association in waf.tf."
}

output "alb_dns_name" {
  value       = module.alb.dns_name
  description = "DNS name of the ALB (public when internet-facing; internal/private when alb_internal = true). curl it: http://<this-value>/"
}

output "compute_ami_id" {
  value       = var.build_compute_ami ? one(aws_imagebuilder_image.pcs_compute[0].output_resources[0].amis[*].image) : null
  description = "AMI ID of the custom PCS compute-node image once built (build_compute_ami = true), else null. Informational: the compute node groups already consume this AMI directly; no manual pin needed."
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.main.name
  description = "ECS cluster name. Used by bootstrap.sh to run the one-off sif-sync task."
}

output "sif_sync_security_group_id" {
  value       = var.enable_pcs ? aws_security_group.sif_sync[0].id : null
  description = "Security group for the sif-sync bootstrap task (enable_pcs only). Used by bootstrap.sh."
}

output "sif_sync_task_definitions" {
  value       = { for k, td in aws_ecs_task_definition.sif_sync : k => td.family }
  description = "Map of workload name -> sif-sync task definition family (empty unless enable_pcs and sif_workloads set). bootstrap.sh runs each to stage that workload's SIF onto EFS."
}
