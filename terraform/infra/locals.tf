data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:We slice the first two AZs explicitly; the result set growing does not change the VPC
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  # Cost allocation tags on every resource (provider default_tags): activate Project/Env/Owner in
  # Billing -> Cost allocation tags so Cost Explorer and the budget can filter on them.
  tags = {
    Project   = var.project
    Env       = var.environment
    Owner     = var.owner
    ManagedBy = "terraform"
  }
}
