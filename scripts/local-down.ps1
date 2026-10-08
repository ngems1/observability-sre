<#
.SYNOPSIS
  Remove OpsDesk from Docker Desktop Kubernetes.
.EXAMPLE
  ./scripts/local-down.ps1          # app, load, Postgres (data deleted), ElasticMQ
  ./scripts/local-down.ps1 -All     # also Prometheus, Grafana, Tempo
#>
param([switch]$All)
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
kubectl config use-context docker-desktop | Out-Null
kubectl delete -f load/k6-deployment.yaml --ignore-not-found
helm uninstall opsdesk -n opsdesk 2>$null
kubectl delete -f deploy/local/ --ignore-not-found
if ($All) {
    kubectl delete -f deploy/observability/dashboards/opsdesk-overview-configmap.yaml --ignore-not-found
    helm uninstall kube-prometheus-stack -n observability 2>$null
    helm uninstall tempo -n observability 2>$null
    kubectl delete namespace observability --ignore-not-found
}
Write-Host "Done." -ForegroundColor Green
