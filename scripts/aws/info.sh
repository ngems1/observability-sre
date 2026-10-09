#!/usr/bin/env bash
# Print what you need to use the EKS deployment: URLs per environment, Grafana login, demo API keys.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_init infra
ensure_init platform
kubeconfig
for env in dev prod; do
  host="$(kubectl -n "opsdesk-${env}" get ingress opsdesk-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  echo "${env} web UI : http://${host:-<not deployed>}/"
  [[ "$env" == "prod" ]] && echo "Grafana     : http://${host:-<not deployed>}/grafana   user: admin   password: $(tf platform output -raw grafana_admin_password)"
done
echo
echo "Demo API keys (also in Secrets Manager: opsdesk-dev/app and opsdesk-prod/app):"
tf infra output -json demo_api_keys | python3 -c 'import sys,json
for env, users in json.load(sys.stdin).items():
    for n, v in users.items(): print(f"  {env:5} {n:6} {v[\"role\"]:9} {v[\"api_key\"]}")'
echo
echo "Your current public IP (must be in allowed_cidrs to open the ALB): run 'curl -s https://checkip.amazonaws.com' on YOUR laptop, not here."
