# 2 AZs: public subnets (ALB, NAT), private subnets (EKS nodes), database subnets (RDS, no internet route).
# One NAT gateway for the demo. The S3 gateway endpoint is free and always on.
# Interface endpoints cost ~$0.01/h per AZ each (6 x 2 AZ = ~$2.90/day): at demo traffic that is MORE than the
# NAT data they save, so they are off by default -- a measured cost trade-off (docs/cost.md).

module "vpc" {
  #checkov:skip=CKV_TF_1:Registry module pinned with a version constraint; .terraform.lock.hcl pins providers
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = var.name
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets   = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, i)]       # 10.40.0.0/24, 10.40.1.0/24
  private_subnets  = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i + 1)]   # 10.40.16.0/20, 10.40.32.0/20
  database_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 100)] # 10.40.100.0/24, 10.40.101.0/24

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  # VPC flow logs for the security baseline (rejected traffic only keeps volume and cost low)
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_traffic_type                           = "REJECT"
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_max_aggregation_interval               = 600

  # Subnet discovery for the AWS Load Balancer Controller
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ------------------------------------------------------------ VPC endpoints
resource "aws_security_group" "vpc_endpoints" {
  count       = var.enable_interface_endpoints ? 1 : 0
  name        = "${var.name}-vpce"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = { Name = "${var.name}-s3" }
}

# ECR pulls, SQS, Secrets Manager, CloudWatch Logs and STS (IRSA) stay inside the VPC
resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset(["ecr.api", "ecr.dkr", "sqs", "secretsmanager", "logs", "sts"]) : toset([])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
  tags                = { Name = "${var.name}-${each.value}" }
}
