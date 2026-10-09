# GitHub Actions -> AWS with OpenID Connect: workflows get short-lived credentials by assuming this role.
# No AWS access keys exist anywhere (not in GitHub secrets, not on a laptop).

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  oidc_url          = "token.actions.githubusercontent.com"
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_url}"

  # Who may assume the role: the main branch, pull requests and the dev / prod environments of ONE repository
  allowed_subjects = [for s in var.allowed_subjects : "repo:${coalesce(var.subject_repository, var.github_repository)}:${s}"]
}

# Only one GitHub provider can exist per account: set create_oidc_provider = false if IAM already has it
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_url}"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's certificate itself; the thumbprints are kept for older API callers
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.oidc_url}:sub"
      values   = local.allowed_subjects
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.role_name
  description          = "Assumed by GitHub Actions (OIDC) for ${var.github_repository} only"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 7200 # EKS creation takes ~20 min; 2 h covers infra + platform in one run
}

# Terraform creates IAM roles, VPCs, EKS, RDS... For this single-purpose lab account the deploy role is admin.
# Documented gap (docs/security/findings.md): split into a read-only plan role and an apply role with a
# permissions boundary in production.
resource "aws_iam_role_policy_attachment" "deploy_admin" {
  #checkov:skip=CKV_AWS_274:Lab account; trust is limited to one repo's main branch, PRs and its dev / prod environments
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}
