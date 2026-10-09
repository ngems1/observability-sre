#!/usr/bin/env bash
# Post-deploy smoke test on EKS (bash twin of scripts/smoke.ps1). Exits non-zero on the first failure.
# Uses a kubectl port-forward so it works from CloudShell and CI regardless of ALB source-IP rules.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PORT="${SMOKE_PORT:-18080}"
ensure_init infra
KEYS_JSON="$(tf infra output -json demo_api_keys | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$APP_ENV")"
key() { python3 -c "import sys,json;print(json.loads(sys.argv[1])[sys.argv[2]]['api_key'])" "$KEYS_JSON" "$1"; }
REQ="$(key alice)"; APPR="$(key bob)"

kubectl -n "$APP_NS" port-forward svc/opsdesk-api "$PORT:80" >/tmp/opsdesk-pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
B="http://127.0.0.1:${PORT}"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; exit 1; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
code() { curl -s -o /tmp/smoke-body.json -w '%{http_code}' "$@"; }
field() { python3 -c "import json,sys;d=json.load(open('/tmp/smoke-body.json'));print(eval(sys.argv[1], {}, {'d': d}))" "$1"; }

for _ in $(seq 1 30); do [[ "$(code "$B/readyz")" == 200 ]] && break; sleep 2; done
check "readyz returns 200" '[[ "$(code "$B/readyz")" == 200 ]]'
check "web UI served with a CSP header" 'curl -sI "$B/ui/" | grep -qi "content-security-policy"'
check "request without API key is rejected (401)" '[[ "$(code "$B/tickets")" == 401 ]]'
check "alert webhook requires its bearer token (401)" '[[ "$(code -X POST "$B/integrations/alertmanager" -H "Content-Type: application/json" -d "{\"alerts\":[]}")" == 401 ]]'

# shellcheck disable=SC2034  # read inside an eval'd check
BODY='{"type":"access_request","title":"Smoke test: read-only on staging","priority":"low","team":"platform","access":{"resource":"staging-eks","requested_role":"read-only","justification":"smoke test","duration_days":1}}'
check "create access request (201)" '[[ "$(code -X POST "$B/tickets" -H "X-API-Key: $REQ" -H "Content-Type: application/json" -d "$BODY")" == 201 ]]'
ID="$(field 'd["id"]')"
# shellcheck disable=SC2034  # read inside an eval'd check
ASSIGNEE="$(field 'd["assignee_id"]')"
check "ticket auto-assigned to an approver" '[[ "$ASSIGNEE" != "None" ]]'
check "requester cannot approve (403)" '[[ "$(code -X POST "$B/tickets/$ID/approve" -H "X-API-Key: $REQ")" == 403 ]]'
check "approver approves (200)" '[[ "$(code -X POST "$B/tickets/$ID/approve" -H "X-API-Key: $APPR" -H "Content-Type: application/json" -d "{\"reason\":\"smoke\"}")" == 200 ]]'
check "second decision conflicts (409)" '[[ "$(code -X POST "$B/tickets/$ID/reject" -H "X-API-Key: $APPR")" == 409 ]]'
check "invalid status jump rejected (409)" '[[ "$(code -X PATCH "$B/tickets/$ID/status" -H "X-API-Key: $APPR" -H "Content-Type: application/json" -d "{\"status\":\"closed\"}")" == 409 ]]'

SENT=0
for _ in $(seq 1 30); do
  code "$B/tickets/$ID/notifications" -H "X-API-Key: $REQ" >/dev/null
  SENT="$(field 'sum(1 for n in d if n["status"]=="sent")')"
  [[ "$SENT" -ge 2 ]] && break
  sleep 2
done
check "worker delivered both notifications via SQS" '[[ "$SENT" -ge 2 ]]'

code "$B/tickets/$ID/audit" -H "X-API-Key: $APPR" >/dev/null
TRACE="$(field 'd[0]["trace_id"]')"
check "audit trail recorded with trace_id" '[[ -n "$TRACE" && "$TRACE" != "None" ]]'
printf '\nSmoke test passed. Ticket OPS-%s, trace %s\n' "$ID" "$TRACE"
