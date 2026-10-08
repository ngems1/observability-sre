# Platform layer: everything installed INTO the EKS cluster (controllers + observability stack).
# Separate root from ../infra so the Kubernetes/Helm providers only run once the cluster exists.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    key          = "opsdesk/demo/platform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "opsdesk/demo/infra.tfstate"
    region = var.region
  }
}

locals {
  infra        = data.terraform_remote_state.infra.outputs
  cluster_name = local.infra.cluster_name
  roles        = local.infra.irsa_role_arns
}

provider "aws" {
  region = var.region
}

# Short-lived token from `aws eks get-token` (AWS CLI is preinstalled in CloudShell)
provider "kubernetes" {
  host                   = local.infra.cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = local.infra.cluster_endpoint
    cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
    }
  }
}
