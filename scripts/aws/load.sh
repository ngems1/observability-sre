#!/usr/bin/env bash
# Start / stop the k6 synthetic load on EKS (same script as Docker Desktop, EKS service URL + real API keys).
#   bash scripts/aws/load.sh          # start (5 req/s)
#   bash scripts/aws/load.sh stop
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_init infra
kubeconfig

if [[ "${1:-start}" == "stop" ]]; then
  kubectl delete namespace load --ignore-not-found
  exit 0
fi

KEYS_JSON="$(tf infra output -json demo_api_keys)"
key() { python3 -c "import sys,json;print(json.loads(sys.argv[1])[sys.argv[2]]['api_key'])" "$KEYS_JSON" "$1"; }

kubectl create namespace load --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace load pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null
sed -e 's/namespace: opsdesk-deps/namespace: load/' \
    -e 's|http://opsdesk-api.opsdesk.svc.cluster.local:8080|http://opsdesk-api.opsdesk.svc.cluster.local|' \
    "$ROOT/load/k6-deployment.yaml" | kubectl apply -f -
kubectl -n load create secret generic k6-keys \
  --from-literal=REQUESTER_KEY="$(key alice)" --from-literal=APPROVER_KEY="$(key bob)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n load set env deploy/k6-load --from=secret/k6-keys >/dev/null
kubectl -n load rollout status deploy/k6-load --timeout=180s
echo "k6 is sending ~5 req/s to opsdesk-api. Stop with: bash scripts/aws/load.sh stop"
