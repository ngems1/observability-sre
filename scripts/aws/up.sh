#!/usr/bin/env bash
# Stand up the whole AWS environment from code, in order:
#   1. bootstrap  - checks the state bucket from terraform/bootstrap exists (run once, docs/aws.md step 2)
#   2. infra      - VPC, EKS, ECR, RDS, SQS+DLQ, KMS, IAM/IRSA, Secrets Manager, CloudWatch, budget  (~20 min)
#   3. platform   - ALB controller, External Secrets, metrics-server, Cluster Autoscaler, Fluent Bit,
#                   Prometheus/Grafana/Alertmanager, Tempo, OTel Collector                              (~10 min)
#   4. app        - build + push image to ECR, helm upgrade --install, smoke test                       (~5 min)
#
#   bash scripts/aws/up.sh             # everything
#   bash scripts/aws/up.sh --skip-app  # stop after the platform layer
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKIP_APP=false
[[ "${1:-}" == "--skip-app" ]] && SKIP_APP=true

command -v terraform >/dev/null || die "terraform not found: run scripts/aws/setup-cloudshell.sh first"
require_tfvars infra
require_tfvars platform
if [[ "${CI:-}" != "true" ]]; then
  grep -q "state_bucket *= *\"${STATE_BUCKET}\"" "$ROOT/terraform/platform/terraform.tfvars" || \
    warn "Check terraform/platform/terraform.tfvars: state_bucket should be \"${STATE_BUCKET}\""
fi

step "1/4 Terraform state bucket (${STATE_BUCKET})"
aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null || \
  die "state bucket missing: run the bootstrap first (terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply)"
echo "exists"

step "2/4 Infrastructure (terraform/infra) - about 20 minutes on first run"
tf_init infra
tf infra apply -input=false -auto-approve
kubeconfig
kubectl get nodes -o wide

step "3/4 Platform layer (terraform/platform)"
tf_init platform
tf platform apply -input=false -auto-approve

if ! $SKIP_APP; then
  step "4/4 Application"
  bash "$ROOT/scripts/aws/deploy-app.sh"
fi

cat <<EOF

Done. Useful next commands:
  bash scripts/aws/info.sh        # URLs, Grafana password, demo API keys
  kubectl get pods -A
  bash scripts/aws/down.sh        # tear everything down when you stop working
EOF
