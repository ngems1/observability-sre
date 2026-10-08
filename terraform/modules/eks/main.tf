# EKS with one managed node group in the private subnets.
# - IRSA enabled (OIDC provider) for the app, the worker and the platform add-ons
# - VPC CNI with network policy enforcement on (the chart's NetworkPolicies are enforced here, unlike Docker Desktop)
# - Access entries: whoever runs Terraform (the GitHub Actions deploy role) is cluster admin

data "aws_partition" "current" {}

module "eks" {
  #checkov:skip=CKV_TF_1:Registry module pinned with a version constraint; .terraform.lock.hcl pins providers
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.subnet_ids
  control_plane_subnet_ids = var.subnet_ids

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.public_access_cidrs
  cluster_endpoint_private_access      = true

  # Control-plane logs to CloudWatch (audit + authenticator for the security story)
  cluster_enabled_log_types              = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  enable_irsa                              = true
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    for i, arn in var.admin_principal_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cluster_addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.irsa_ebs_csi.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = var.node_ami_type
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # IMDSv2 only, hop limit 1: pods cannot borrow the node's IAM role (they use IRSA)
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 40
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      labels = { workload = "general" }

      # EKS also puts these on the node group ASG, which is what Cluster Autoscaler auto-discovery reads
      tags = {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }

  # Webhook ports (ALB controller / ESO on 9443) are covered by the module's recommended node SG rules.
}

# The EBS CSI driver add-on needs its own IAM role (PVCs for Prometheus and Tempo); it lives with the cluster.
module "irsa_ebs_csi" {
  #checkov:skip=CKV_TF_1:Registry module pinned with a version constraint
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
