# Cluster controllers. Each one runs with its own IRSA role from ../infra.
# Nodes use IMDSv2 with hop limit 1, so region / VPC id are passed explicitly.

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = lookup(var.chart_versions, "aws_lb_controller", null)
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    clusterName  = local.cluster_name
    region       = var.region
    vpcId        = local.infra.vpc_id
    replicaCount = 1
    serviceAccount = {
      name        = "aws-load-balancer-controller"
      annotations = { "eks.amazonaws.com/role-arn" = local.roles.lb_controller }
    }
  })]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = lookup(var.chart_versions, "external_secrets", null)
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 600

  # No AWS role on the controller itself: each environment's SecretStore authenticates with a service account
  # in its own namespace (IRSA role trusted only there), so dev can never read prod's secrets.
  values = [yamlencode({
    installCRDs = true
    serviceAccount = {
      name = "external-secrets"
    }
    # region for the AWS SDK inside the controller (no IMDS access from pods)
    extraEnv = [{ name = "AWS_REGION", value = var.region }]
  })]

  depends_on = [helm_release.aws_lb_controller]
}

# Required by the HPA on ticket-api
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = lookup(var.chart_versions, "metrics_server", null)
  namespace  = "kube-system"
  wait       = true

  depends_on = [helm_release.aws_lb_controller]
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = lookup(var.chart_versions, "cluster_autoscaler", null)
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    awsRegion     = var.region
    autoDiscovery = { clusterName = local.cluster_name }
    rbac = {
      serviceAccount = {
        name        = "cluster-autoscaler"
        annotations = { "eks.amazonaws.com/role-arn" = local.roles.cluster_autoscaler }
      }
    }
    extraArgs = {
      "balance-similar-node-groups"      = true
      "skip-nodes-with-system-pods"      = false
      "scale-down-unneeded-time"         = "5m"
      "scale-down-utilization-threshold" = "0.5"
      "expander"                         = "least-waste"
    }
  })]

  depends_on = [helm_release.aws_lb_controller]
}

# Ships ONLY the application namespaces' container logs to CloudWatch (cost: less ingestion),
# each environment to its own log group: /opsdesk-dev/application, /opsdesk-prod/application
resource "helm_release" "fluent_bit" {
  name       = "aws-for-fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  version    = lookup(var.chart_versions, "fluent_bit", null)
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name
  wait       = true

  values = [yamlencode({
    serviceAccount = {
      name        = "aws-for-fluent-bit"
      annotations = { "eks.amazonaws.com/role-arn" = local.roles.fluent_bit }
    }
    input = {
      path = "/var/log/containers/*_opsdesk-*_*.log" # <pod>_<namespace>_<container>-<id>.log
    }
    # The app writes JSON: parse it into fields under "data" and drop the raw copy (half the ingestion)
    filter = {
      mergeLog    = "On"
      mergeLogKey = "data"
      keepLog     = "Off"
    }
    cloudWatch = { enabled = false } # legacy Go plugin
    cloudWatchLogs = {
      enabled          = true
      region           = var.region
      logGroupTemplate = "/$kubernetes['namespace_name']/application"
      logGroupName     = local.environments["prod"].log_group # fallback if the namespace field is missing
      logStreamPrefix  = "pod-"
      autoCreateGroup  = false # Terraform owns the group (retention + KMS)
    }
    firehose      = { enabled = false }
    kinesis       = { enabled = false }
    elasticsearch = { enabled = false }
  })]

  depends_on = [helm_release.aws_lb_controller]
}

# ---------------------------------------------------------------- external-dns: Ingress -> Route 53
# The load balancer controller creates the ALB, so its hostname is not known until after the apply.
# external-dns closes that loop: it reads the host on each Ingress and keeps an alias record pointing at
# whichever ALB currently serves it. After a nightly Destroy the records go stale for as long as the
# environment is down, then are repointed automatically on the next deploy.
resource "helm_release" "external_dns" {
  count      = var.domain_name == "" ? 0 : 1
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = lookup(var.chart_versions, "external_dns", null)
  namespace  = "kube-system"

  values = [yamlencode({
    provider      = { name = "aws" }
    aws           = { region = var.region, zoneType = "public" }
    domainFilters = [var.domain_name] # never touch records outside this zone
    sources       = ["ingress"]
    policy        = "sync"                # remove records when their Ingress goes away
    txtOwnerId    = local.cluster_name    # stable across rebuilds, so it recognises its own records
    serviceAccount = {
      name        = "external-dns"
      annotations = { "eks.amazonaws.com/role-arn" = local.roles.external_dns }
    }
    resources = {
      requests = { cpu = "10m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  })]

  depends_on = [helm_release.aws_lb_controller]
}
