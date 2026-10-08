# In-cluster observability: Prometheus + Alertmanager + Grafana (kube-prometheus-stack),
# Tempo for traces, and an OpenTelemetry Collector in front of Tempo.
#   app --OTLP/HTTP:4318--> otel-collector (batch, memory limits) --OTLP/gRPC--> tempo
# Grafana is published on the shared ALB at /grafana, restricted to var.allowed_cidrs.

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

# Readable in the AWS console (Secrets Manager -> opsdesk-demo/grafana) - no CLI needed
resource "aws_secretsmanager_secret" "grafana" {
  #checkov:skip=CKV2_AWS_57:Rotate with terraform apply -replace=random_password.grafana_admin
  name                    = "opsdesk-demo/grafana"
  description             = "Grafana admin login for the OpsDesk demo"
  kms_key_id              = local.infra.kms_key_arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({ username = "admin", password = random_password.grafana_admin.result })
}

locals {
  alb_common_annotations = {
    "alb.ingress.kubernetes.io/scheme"        = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"   = "ip"
    "alb.ingress.kubernetes.io/group.name"    = "opsdesk"
    "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", var.allowed_cidrs)
    "alb.ingress.kubernetes.io/listen-ports"  = "[{\"HTTP\": 80}]"
  }
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

# Alertmanager -> OpsDesk incident tickets. The bearer token is the one the API reads from Secrets Manager
# (infra root); Alertmanager reads it from this Secret, mounted at /etc/alertmanager/secrets/<name>/token.
resource "kubernetes_secret_v1" "alertmanager_opsdesk" {
  metadata {
    name      = "alertmanager-opsdesk-webhook"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = { token = local.infra.alert_webhook_token }
}

locals {
  # Critical alerts, and warnings that name an owning team, open an incident follow-up ticket in OpsDesk.
  alertmanager_config = {
    global = { resolve_timeout = "5m" }
    route = {
      receiver        = "null"
      group_by        = ["alertname", "namespace"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
      routes = [
        { receiver = "null", matchers = ["alertname=~\"Watchdog|InfoInhibitor\""] },
        { receiver = "opsdesk", matchers = ["severity=\"critical\""] },
        { receiver = "opsdesk", matchers = ["severity=\"warning\"", "team=~\".+\""] },
      ]
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
    receivers = [
      { name = "null" },
      {
        name = "opsdesk"
        webhook_configs = [{
          url           = "http://opsdesk-api.${var.app_namespace}.svc.cluster.local:80/integrations/alertmanager"
          send_resolved = true
          max_alerts    = 50
          http_config = {
            authorization = {
              type             = "Bearer"
              credentials_file = "/etc/alertmanager/secrets/${kubernetes_secret_v1.alertmanager_opsdesk.metadata[0].name}/token"
            }
          }
        }]
      },
    ]
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
        hosts            = []
        annotations = merge(local.alb_common_annotations, {
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
