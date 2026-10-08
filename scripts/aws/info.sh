#!/usr/bin/env bash
# Print what you need to use the EKS deployment: URLs, Grafana login, demo API keys.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_init infra
ensure_init platform
kubeconfig
HOST="$(kubectl -n "$APP_NS" get ingress opsdesk-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
echo "Web UI : http://${HOST:-<not ready>}/"
echo "Grafana: http://${HOST:-<not ready>}/grafana   user: admin   password: $(tf platform output -raw grafana_admin_password)"
echo
echo "Demo API keys (also in Secrets Manager: opsdesk-demo/app):"
tf infra output -json demo_api_keys | python3 -c 'import sys,json
for n,v in json.load(sys.stdin).items(): print(f"  {n:6} {v[\"role\"]:9} {v[\"api_key\"]}")'
echo
echo "Your current public IP (must be in allowed_cidrs to open the ALB): run 'curl -s https://checkip.amazonaws.com' on YOUR laptop, not here."
