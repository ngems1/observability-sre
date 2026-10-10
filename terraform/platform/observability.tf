# In-cluster observability: Prometheus + Alertmanager + Grafana (kube-prometheus-stack),
# Tempo for traces, and an OpenTelemetry Collector in front of Tempo.
#   app --OTLP/HTTP:4318--> otel-collector (batch, memory limits) --OTLP/gRPC--> tempo
# Grafana is published on the shared ALB at /grafana, restricted to var.allowed_cidrs.

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

# Readable in the AWS console (Secrets Manager -> opsdesk/grafana) - no CLI needed
resource "aws_secretsmanager_secret" "grafana" {
  #checkov:skip=CKV2_AWS_57:Rotate with terraform apply -replace=random_password.grafana_admin
  name                    = "opsdesk/grafana"
  description             = "Grafana admin login for the OpsDesk demo"
  kms_key_id              = local.infra.kms_key_arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({ username = "admin", password = random_password.grafana_admin.result })
}

# Issued by terraform/bootstrap and left out of the nightly teardown, so it is looked up, not created.
data "aws_acm_certificate" "this" {
  count       = var.domain_name == "" ? 0 : 1
  domain      = var.domain_name # the certificate also carries *.<domain> as a SAN
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  # One hostname per environment. Grafana stays on /grafana of each, because it is served from a sub-path
  # (grafana.ini root_url) and each environment's URL should carry its own monitoring link.
  env_hosts = var.domain_name == "" ? {} : {
    dev  = "dev.${var.domain_name}"
    prod = "opsdesk.${var.domain_name}"
  }

  # Without a domain there is no certificate, so the listener stays HTTP-only on the raw ALB hostname.
  alb_tls_annotations = var.domain_name == "" ? {
    "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}]"
    } : {
    "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
    "alb.ingress.kubernetes.io/certificate-arn" = data.aws_acm_certificate.this[0].arn
    "alb.ingress.kubernetes.io/ssl-redirect"    = "443" # the controller adds the 80 -> 443 redirect rule
    "alb.ingress.kubernetes.io/ssl-policy"      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  }

  alb_common_annotations = merge({
    "alb.ingress.kubernetes.io/scheme"        = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"   = "ip"
    "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", var.allowed_cidrs)
  }, local.alb_tls_annotations)
}

resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = lookup(var.chart_versions, "tempo", null)
  namespace  = kubernetes_namespace_v1.observability.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode({
    tempo = {
      retention = "72h"
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
      }
      resources = {
        requests = { cpu = "50m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
    }
    persistence = {
      enabled          = true
      storageClassName = kubernetes_storage_class_v1.gp3.metadata[0].name
      size             = "10Gi"
    }
  })]

  depends_on = [helm_release.aws_lb_controller]
}

resource "helm_release" "otel_collector" {
  name       = "otel-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = lookup(var.chart_versions, "otel_collector", null)
  namespace  = kubernetes_namespace_v1.observability.metadata[0].name
  wait       = true

  values = [yamlencode({
    fullnameOverride = "otel-collector" # service: otel-collector.observability:4318
    mode             = "deployment"
    replicaCount     = 1
    image            = { repository = "otel/opentelemetry-collector-contrib" }
    command          = { name = "otelcol-contrib" }
    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "512Mi" }
    }
    config = {
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "$${env:MY_POD_IP}:4317" }
            http = { endpoint = "$${env:MY_POD_IP}:4318" }
          }
        }
      }
      processors = {
        memory_limiter = { check_interval = "1s", limit_percentage = 80, spike_limit_percentage = 20 }
        batch          = { timeout = "5s", send_batch_size = 512 }
      }
      exporters = {
        "otlp/tempo" = {
          endpoint = "tempo.observability.svc.cluster.local:4317"
          tls      = { insecure = true }
        }
      }
      service = {
        pipelines = {
          traces = {
            receivers  = ["otlp"]
            processors = ["memory_limiter", "batch"]
            exporters  = ["otlp/tempo"]
          }
        }
      }
    }
  })]

  depends_on = [helm_release.tempo]
}

# Alertmanager -> OpsDesk incident tickets, per environment: alerts from namespace opsdesk-dev open tickets in
# dev's OpsDesk, opsdesk-prod in prod's. Platform-wide critical alerts (no app namespace) go to prod's OpsDesk.
# Each environment's bearer token comes from its Secrets Manager secret (infra root); Alertmanager reads them
# from this Secret, mounted at /etc/alertmanager/secrets/alertmanager-opsdesk-webhook/token-<env>.
resource "kubernetes_secret_v1" "alertmanager_opsdesk" {
  metadata {
    name      = "alertmanager-opsdesk-webhook"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = { for env, token in local.infra.alert_webhook_tokens : "token-${env}" => token }
}

locals {
  am_secret_dir = "/etc/alertmanager/secrets/alertmanager-opsdesk-webhook"

  # Per environment: critical alerts, and warnings that name an owning team, open a ticket
  am_env_routes = flatten([
    for env, e in local.environments : [
      { receiver = "opsdesk-${env}", matchers = ["namespace=\"${e.namespace}\"", "severity=\"critical\""] },
      { receiver = "opsdesk-${env}", matchers = ["namespace=\"${e.namespace}\"", "severity=\"warning\"", "team=~\".+\""] },
      { receiver = "null", matchers = ["namespace=\"${e.namespace}\""] },
    ]
  ])

  am_env_receivers = [
    for env, e in local.environments : {
      name = "opsdesk-${env}"
      webhook_configs = [{
        url           = "http://opsdesk-api.${e.namespace}.svc.cluster.local:80/integrations/alertmanager"
        send_resolved = true
        max_alerts    = 50
        http_config = {
          authorization = {
            type             = "Bearer"
            credentials_file = "${local.am_secret_dir}/token-${env}"
          }
        }
      }]
    }
  ]

  alertmanager_config = {
    global = { resolve_timeout = "5m" }
    route = {
      receiver        = "null"
      group_by        = ["alertname", "namespace"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
      routes = concat(
        [{ receiver = "null", matchers = ["alertname=~\"Watchdog|InfoInhibitor\""] }],
        local.am_env_routes,
        # platform-wide critical alerts (nodes, CoreDNS, monitoring) are tracked in prod's OpsDesk
        [{ receiver = "opsdesk-prod", matchers = ["severity=\"critical\""] }],
      )
    }
    inhibit_rules = [
      {
        source_matchers = ["severity=\"critical\""]
        target_matchers = ["severity=\"warning\""]
        equal           = ["alertname", "namespace"]
      },
      # cause alerts (a layer) mute symptom alerts (SLO burn, latency): the ticket names the failing layer
      {
        source_matchers = ["alert_type=\"cause\""]
        target_matchers = ["alert_type=\"symptom\""]
        equal           = ["namespace"]
      },
      {
        source_matchers = ["alertname=~\"OpsDeskDependencyUnreachable|OpsDeskDatabaseErrors\""]
        target_matchers = ["alertname=\"OpsDeskPodsUnavailable\""]
        equal           = ["namespace"]
      },
      {
        source_matchers = ["alertname=\"OpsDeskWorkerDown\""]
        target_matchers = ["alertname=\"OpsDeskQueueBacklog\""]
        equal           = ["namespace"]
      },
    ]
    receivers = concat([{ name = "null" }], local.am_env_receivers)
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = lookup(var.chart_versions, "kube_prometheus_stack", null)
  namespace  = kubernetes_namespace_v1.observability.metadata[0].name
  wait       = true
  timeout    = 900

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        retention                               = var.prometheus_retention
        enableFeatures                          = ["exemplar-storage"]
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        resources                               = { requests = { cpu = "200m", memory = "1Gi" } }
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = kubernetes_storage_class_v1.gp3.metadata[0].name
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = "20Gi" } }
            }
          }
        }
      }
    }
    alertmanager = {
      config = local.alertmanager_config
      alertmanagerSpec = {
        secrets   = [kubernetes_secret_v1.alertmanager_opsdesk.metadata[0].name]
        resources = { requests = { cpu = "10m", memory = "64Mi" } }
      }
    }
    grafana = {
      adminPassword = random_password.grafana_admin.result
      "grafana.ini" = {
        server = {
          root_url            = "%(protocol)s://%(domain)s/grafana/"
          serve_from_sub_path = true
        }
        "auth.anonymous" = { enabled = false }
      }
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        path             = "/grafana"
        pathType         = "Prefix"
        hosts            = compact([try(local.env_hosts["prod"], "")])
        # Grafana is a platform tool: one instance, reachable at /grafana on both environments' load balancers
        annotations = merge(local.alb_common_annotations, {
          "alb.ingress.kubernetes.io/group.name"       = "opsdesk-prod"
          "alb.ingress.kubernetes.io/group.order"      = "10"
          "alb.ingress.kubernetes.io/healthcheck-path" = "/grafana/api/health"
        })
      }
      sidecar = {
        dashboards = { enabled = true, searchNamespace = "ALL" }
        datasources = {
          exemplarTraceIdDestinations = { datasourceUid = "tempo", traceIdLabelName = "trace_id" }
        }
      }
      additionalDataSources = [{
        name     = "Tempo"
        uid      = "tempo"
        type     = "tempo"
        access   = "proxy"
        url      = "http://tempo.observability.svc.cluster.local:3200"
        jsonData = { serviceMap = { datasourceUid = "prometheus" }, nodeGraph = { enabled = true } }
      }]
    }
    # EKS control-plane components are managed by AWS and not scrapeable
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }
  })]

  depends_on = [helm_release.aws_lb_controller, helm_release.tempo, kubernetes_secret_v1.alertmanager_opsdesk]
}

# The same (single) Grafana also on dev's load balancer at /grafana, so each environment's URL has its
# monitoring link. Pick the environment with the dashboards' "Environment" dropdown.
resource "kubernetes_ingress_v1" "grafana_dev" {
  metadata {
    name      = "grafana-dev"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
    annotations = merge(local.alb_common_annotations, {
      "alb.ingress.kubernetes.io/group.name"       = "opsdesk-dev"
      "alb.ingress.kubernetes.io/group.order"      = "10"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/grafana/api/health"
    })
  }
  spec {
    ingress_class_name = "alb"
    rule {
      host = try(local.env_hosts["dev"], null)
      http {
        path {
          path      = "/grafana"
          path_type = "Prefix"
          backend {
            service {
              name = "${helm_release.kube_prometheus_stack.name}-grafana"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# Same dashboards as Docker Desktop, loaded by the Grafana sidecar:
#   opsdesk-overview      service view (SLOs, RED, worker, business, incidents)
#   opsdesk-fault-domain  incident triage: one row per layer, "where is the fault?"
resource "kubernetes_config_map_v1" "opsdesk_dashboard" {
  for_each = toset(["opsdesk-overview", "opsdesk-fault-domain"])
  metadata {
    name      = "${each.key}-dashboard"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    "${each.key}.json" = file("${path.module}/../../deploy/observability/dashboards/${each.key}.json")
  }
  depends_on = [helm_release.kube_prometheus_stack]
}
