output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs (EKS nodes and control-plane ENIs)."
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnet IDs (ALB, NAT gateway)."
  value       = module.vpc.public_subnets
}

output "database_subnet_group_name" {
  description = "DB subnet group for RDS (database subnets, no internet route)."
  value       = module.vpc.database_subnet_group_name
}
