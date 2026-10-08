<#
.SYNOPSIS
  Build OpsDesk and deploy it to Docker Desktop Kubernetes.

.EXAMPLE
  ./scripts/local-up.ps1                      # app + Postgres + ElasticMQ
  ./scripts/local-up.ps1 -Observability       # + Prometheus, Grafana, Tempo, dashboard
  ./scripts/local-up.ps1 -Observability -Load # + continuous k6 traffic
#>
param(
    [switch]$Observability,
    [switch]$Load,
    [switch]$SkipBuild
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Run([string]$exe, [string[]]$argv) {
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "$exe $($argv -join ' ') failed (exit $LASTEXITCODE)" }
}

Step "Using the docker-desktop Kubernetes context"
Run kubectl @("config", "use-context", "docker-desktop")

# Every build gets a unique, immutable tag (same idea as the commit-SHA tags in CI)
$tag = "local-" + (Get-Date -Format "yyyyMMdd-HHmmss")
if ($SkipBuild) {
    $tag = (& kubectl -n opsdesk get deploy opsdesk-api -o jsonpath="{.spec.template.spec.containers[0].image}" 2>$null) -replace '^.*:', ''
    if (-not $tag) { throw "-SkipBuild needs an existing deployment" }
} else {
    Step "Building image opsdesk:$tag"
    Run docker @("build", "-t", "opsdesk:$tag", "./app")
}

Step "Deploying dependencies (Postgres, ElasticMQ)"
Run kubectl @("apply", "-f", "deploy/local/")
Run kubectl @("-n", "opsdesk-deps", "rollout", "status", "statefulset/postgres", "--timeout=180s")
Run kubectl @("-n", "opsdesk-deps", "rollout", "status", "deploy/elasticmq", "--timeout=120s")

if ($Observability) {
    Step "Installing kube-prometheus-stack + Tempo (namespace observability)"
    Run helm @("repo", "add", "prometheus-community", "https://prometheus-community.github.io/helm-charts", "--force-update")
    Run helm @("repo", "add", "grafana", "https://grafana.github.io/helm-charts", "--force-update")
    Run helm @("repo", "update")
    Run helm @("upgrade", "--install", "tempo", "grafana/tempo", "-n", "observability", "--create-namespace",
               "-f", "deploy/observability/tempo-values.yaml", "--wait", "--timeout", "5m")
    Run helm @("upgrade", "--install", "kube-prometheus-stack", "prometheus-community/kube-prometheus-stack",
               "-n", "observability", "-f", "deploy/observability/kube-prometheus-stack-values.yaml",
               "--wait", "--timeout", "10m")
    Run kubectl @("apply", "-f", "deploy/observability/dashboards/opsdesk-overview-configmap.yaml",
                  "-f", "deploy/observability/dashboards/opsdesk-fault-domain-configmap.yaml")
}

$extra = @()
$hasCrd = & kubectl get crd servicemonitors.monitoring.coreos.com --ignore-not-found -o name
if (-not $hasCrd) {
    Write-Host "Prometheus Operator not installed: ServiceMonitors disabled" -ForegroundColor Yellow
    $extra += @("--set", "monitoring.serviceMonitor.enabled=false", "--set", "monitoring.prometheusRule.enabled=false")
}
$hasTempo = & kubectl -n observability get svc tempo --ignore-not-found -o name 2>$null
if (-not $hasTempo) {
    Write-Host "Tempo not installed: trace export disabled (trace_id still in logs)" -ForegroundColor Yellow
    $extra += @("--set", "config.OPSDESK_OTEL_EXPORTER_OTLP_ENDPOINT=")
}

# Alert runbook links point at docs/runbook.md on GitHub once the repo has a GitHub remote
$remote = (& git remote get-url origin 2>$null)
if ($remote -match 'github\.com[:/]([^/]+/[^/.]+?)(\.git)?$') {
    $extra += @("--set-string", "monitoring.prometheusRule.runbookBaseUrl=https://github.com/$($Matches[1])/blob/main/docs/runbook.md")
}

Step "Deploying OpsDesk (helm upgrade --install --atomic)"
Run helm (@("upgrade", "--install", "opsdesk", "helm/opsdesk", "-n", "opsdesk",
            "-f", "helm/opsdesk/values-local.yaml", "--set", "image.tag=$tag",
            "--atomic", "--wait", "--timeout", "5m") + $extra)

if ($Load) {
    Step "Starting k6 synthetic load (5 req/s)"
    Run kubectl @("apply", "-f", "load/k6-deployment.yaml")
}

Step "Smoke test"
& "$PSScriptRoot/smoke.ps1"

Write-Host "`nWeb UI   : http://localhost:8080/   (pick a demo user on the sign-in page)" -ForegroundColor Green
Write-Host "API docs : http://localhost:8080/docs" -ForegroundColor Green
if ($Observability -or $hasTempo) {
    Write-Host "Grafana  : http://localhost:3000  (admin / opsdesk-local) -> dashboard 'OpsDesk - Service overview'" -ForegroundColor Green
}
