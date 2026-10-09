#!/usr/bin/env bash
# Start / stop the k6 synthetic load in one environment (same script as Docker Desktop).
# k6 runs INSIDE the environment's namespace: the NetworkPolicies only admit traffic from the same namespace.
#   APP_ENV=dev bash scripts/aws/load.sh          # start (5 req/s)
#   APP_ENV=dev bash scripts/aws/load.sh stop
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_init infra
kubeconfig

if [[ "${1:-start}" == "stop" ]]; then
  kubectl -n "$APP_NS" delete deploy/k6-load configmap/k6-script secret/k6-keys --ignore-not-found
  exit 0
fi

KEYS_JSON="$(tf infra output -json demo_api_keys | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$APP_ENV")"
key() { python3 -c "import sys,json;print(json.loads(sys.argv[1])[sys.argv[2]]['api_key'])" "$KEYS_JSON" "$1"; }

sed -e "s/namespace: opsdesk-deps/namespace: ${APP_NS}/" \
    -e 's|http://opsdesk-api.opsdesk.svc.cluster.local:8080|http://opsdesk-api|' \
    "$ROOT/load/k6-deployment.yaml" | kubectl apply -f -
kubectl -n "$APP_NS" create secret generic k6-keys \
  --from-literal=REQUESTER_KEY="$(key alice)" --from-literal=APPROVER_KEY="$(key bob)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$APP_NS" set env deploy/k6-load --from=secret/k6-keys >/dev/null
kubectl -n "$APP_NS" rollout status deploy/k6-load --timeout=180s
echo "k6 is sending ~5 req/s to opsdesk-api in ${APP_NS}. Stop with: APP_ENV=${APP_ENV} bash scripts/aws/load.sh stop"
