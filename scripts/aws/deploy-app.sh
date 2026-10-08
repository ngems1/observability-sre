#!/usr/bin/env bash
# Build the image, push it to ECR with an immutable tag, deploy with Helm (--atomic), smoke test.
# Stage 3 moves exactly these steps into GitHub Actions (OIDC, Trivy gate, protected environment).
#   bash scripts/aws/deploy-app.sh            # build + deploy
#   TAG=<existing-tag> bash scripts/aws/deploy-app.sh --no-build
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUILD=true
[[ "${1:-}" == "--no-build" ]] && BUILD=false

ensure_init infra
ensure_init platform
kubeconfig
REPO="$(tf infra output -raw ecr_repository_url)"
REGISTRY="${REPO%%/*}"
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
TAG="${TAG:-${GIT_SHA}-$(date -u +%Y%m%d%H%M%S)}"

if $BUILD; then
  step "Build ${REPO}:${TAG}"
  command -v docker >/dev/null || die "docker is not available here; build in CI (stage 3) or on a machine with Docker"
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"
  docker build --platform linux/amd64 -t "${REPO}:${TAG}" "$ROOT/app"
  docker push "${REPO}:${TAG}"
  docker image rm "${REPO}:${TAG}" >/dev/null || true   # CloudShell disk is small
  step "ECR scan-on-push result"
  aws ecr wait image-scan-complete --repository-name opsdesk --image-id imageTag="$TAG" 2>/dev/null || true
  aws ecr describe-image-scan-findings --repository-name opsdesk --image-id imageTag="$TAG" \
    --query 'imageScanFindings.findingSeverityCounts' --output table 2>/dev/null || echo "(scan still running)"
fi

step "Generate Helm values from Terraform outputs"
GEN="$ROOT/helm/opsdesk/values-eks.generated.yaml"
GEN_PLATFORM="$ROOT/helm/opsdesk/values-eks.platform.generated.yaml"
tf infra output -raw helm_values > "$GEN"
tf platform output -raw helm_values > "$GEN_PLATFORM"

# Alert annotations link to docs/runbook.md in this repository (GitHub Actions sets GITHUB_REPOSITORY;
# in CloudShell it is derived from the git remote).
REPO_SLUG="${GITHUB_REPOSITORY:-$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#p')}"
RUNBOOK_URL=""
[[ -n "$REPO_SLUG" ]] && RUNBOOK_URL="${GITHUB_SERVER_URL:-https://github.com}/${REPO_SLUG}/blob/main/docs/runbook.md"

step "helm upgrade --install (atomic)"
helm upgrade --install opsdesk "$ROOT/helm/opsdesk" -n "$APP_NS" \
  -f "$ROOT/helm/opsdesk/values-eks.yaml" -f "$GEN" -f "$GEN_PLATFORM" \
  --set image.tag="$TAG" \
  --set-string monitoring.prometheusRule.runbookBaseUrl="$RUNBOOK_URL" \
  --atomic --wait --timeout 10m
helm history opsdesk -n "$APP_NS" --max 5

step "Waiting for the ALB"
for _ in $(seq 1 40); do
  HOST="$(kubectl -n "$APP_NS" get ingress opsdesk-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "$HOST" ]] && break
  sleep 10
done
[[ -n "${HOST:-}" ]] || warn "ALB hostname not assigned yet: kubectl -n $APP_NS describe ingress opsdesk-api"

step "Smoke test (through a port-forward: CloudShell is not in the ALB's allowed CIDRs)"
bash "$ROOT/scripts/aws/smoke.sh"

cat <<EOF

Deployed opsdesk:${TAG}
  URLs, Grafana password and demo API keys:  bash scripts/aws/info.sh
  Rollback:                                  helm rollback opsdesk 0 -n ${APP_NS}
EOF
