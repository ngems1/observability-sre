# Cluster basics: default gp3 storage class and the namespaces (with Pod Security levels).

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# One namespace per application environment (opsdesk-dev, opsdesk-prod): the tenant boundary.
# Isolation inside the shared cluster:
#   - Pod Security "restricted" (no root, no privilege escalation, no host access)
#   - ResourceQuota: an environment cannot consume another one's capacity
#   - LimitRange: default requests/limits for any container that forgets them (quota needs requests)
#   - NetworkPolicies from the Helm chart: no traffic between environments
#   - IAM: each environment's pods assume roles trusted only in their own namespace (terraform/modules/environment)
resource "kubernetes_namespace_v1" "app" {
  for_each = local.environments
  metadata {
    name = each.value.namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "opsdesk.io/environment"             = each.key
    }
  }
}

resource "kubernetes_resource_quota_v1" "app" {
  for_each = local.environments
  metadata {
    name      = "environment-quota"
    namespace = kubernetes_namespace_v1.app[each.key].metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = var.namespace_quotas[each.key].requests_cpu
      "requests.memory" = var.namespace_quotas[each.key].requests_memory
      "limits.memory"   = var.namespace_quotas[each.key].limits_memory
      "pods"            = var.namespace_quotas[each.key].pods
    }
  }
}

resource "kubernetes_limit_range_v1" "app" {
  for_each = local.environments
  metadata {
    name      = "container-defaults"
    namespace = kubernetes_namespace_v1.app[each.key].metadata[0].name
  }
  spec {
    limit {
      type            = "Container"
      default_request = { cpu = "50m", memory = "64Mi" }
      default         = { memory = "256Mi" }
    }
  }
}

resource "kubernetes_namespace_v1" "observability" {
  metadata {
    name = "observability"
    labels = {
      # node-exporter needs host access
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "kubernetes_namespace_v1" "logging" {
  metadata {
    name = "logging"
    labels = {
      # Fluent Bit reads /var/log on the node
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}
