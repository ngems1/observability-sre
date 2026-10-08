# PostgreSQL 16 on RDS: private database subnets, encrypted with the app CMK,
# master password generated and rotated by RDS in Secrets Manager (never in Terraform state or Git).

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "PostgreSQL from EKS nodes only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from EKS worker nodes (pods use the node security group)"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.allowed_security_group_id
}

resource "aws_db_parameter_group" "pg16" {
  name   = "${var.name}-pg16"
  family = "postgres16"

  parameter {
    name  = "log_min_duration_statement"
    value = "500" # slow queries (failure drill 2) land in the RDS log
  }
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
}

resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_293:Demo environment is destroyed daily; deletion protection on in production
  #checkov:skip=CKV_AWS_157:Single-AZ for cost (multi_az variable); Multi-AZ in production
  #checkov:skip=CKV_AWS_353:Performance Insights optional (performance_insights variable); slow-query log covers drill 2
  #checkov:skip=CKV_AWS_118:Enhanced monitoring adds cost; CloudWatch RDS metrics + alarms are enough for the demo
  identifier     = "${var.name}-pg"
  engine         = "postgres"
  engine_version = "16"

  instance_class        = var.instance_class
  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.allocated_storage_gb * 2
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name                       = var.db_name
  username                      = "opsdesk_admin"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.multi_az
  parameter_group_name   = aws_db_parameter_group.pg16.name

  backup_retention_period         = 1 # demo; 7+ in production
  enabled_cloudwatch_logs_exports = ["postgresql"]
  # Off by default: not offered on every micro class. Slow queries still reach CloudWatch via the
  # postgresql log export + log_min_duration_statement.
  performance_insights_enabled = var.performance_insights
  monitoring_interval          = 0
  auto_minor_version_upgrade   = true
  copy_tags_to_snapshot        = true

  # IAM auth available for humans/tools (break-glass access without the master password)
  iam_database_authentication_enabled = true

  deletion_protection = false # demo: allow terraform destroy
  skip_final_snapshot = true
  apply_immediately   = true

  # create the log group first (retention + KMS) so RDS does not create an unmanaged one
  depends_on = [aws_cloudwatch_log_group.rds]
}

resource "aws_cloudwatch_log_group" "rds" {
  #checkov:skip=CKV_AWS_338:7-day retention is a deliberate cost decision (docs/cost.md)
  name              = "/aws/rds/instance/${var.name}-pg/postgresql"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}
