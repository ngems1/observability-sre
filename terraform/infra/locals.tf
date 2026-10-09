data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:We slice the first two AZs explicitly; the result set growing does not change the VPC
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Shared platform resources are named <project> (cluster "opsdesk"); each environment's are <project>-<env>
  name = var.project
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  # dev -> namespace opsdesk-dev, resources opsdesk-dev-*; prod -> opsdesk-prod
  environments = { for e in var.environments : e => "${var.project}-${e}" }

  # Cost allocation tags on every resource (provider default_tags): activate Project/Env/Owner in
  # Billing -> Cost allocation tags so Cost Explorer and the budget can filter on them.
  tags = {
    Project   = var.project
    Env       = "shared" # per-environment resources override this with Env = dev / prod
    Owner     = var.owner
    ManagedBy = "terraform"
  }
}
