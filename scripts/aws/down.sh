#!/usr/bin/env bash
# Tear down everything (keeps only the Terraform state bucket). Run it whenever you stop working:
# EKS + NAT + RDS + ALB cost money every hour they exist.
#   bash scripts/aws/down.sh
#
# Order matters: delete the Ingresses first so the ALB controller removes the ALB, otherwise
# the VPC cannot be destroyed (the ALB's network interfaces sit in the public subnets).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Non-interactive in CI: the destroy workflow passes CONFIRM=destroy after its own confirmation input
ok="${CONFIRM:-}"
[[ -n "$ok" ]] || read -r -p "Destroy the OpsDesk AWS environment in account ${ACCOUNT_ID}? Type 'destroy': " ok
[[ "$ok" == "destroy" ]] || die "aborted"

if aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  kubeconfig
  step "Uninstall the app (removes its Ingress)"
  helm uninstall opsdesk -n "$APP_NS" --wait 2>/dev/null || true
  kubectl delete ingress --all -A --wait=true --timeout=5m 2>/dev/null || true

  step "Wait for the ALB to disappear"
  for _ in $(seq 1 30); do
    n="$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?contains(LoadBalancerName, 'k8s-opsdesk')])" --output text 2>/dev/null || echo 0)"
    [[ "$n" == "0" ]] && break
    sleep 10
  done

  step "Destroy the platform layer (also deletes PVCs -> EBS volumes)"
  tf_init platform
  tf platform destroy -input=false -auto-approve || warn "platform destroy reported errors; continuing"
fi

step "Destroy the infrastructure"
tf_init infra
tf infra destroy -input=false -auto-approve

step "Leftover check"
aws ec2 describe-volumes --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=observability \
  --query 'Volumes[].VolumeId' --output text || true
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text || true
echo "Done. The state bucket ${STATE_BUCKET} is kept (a few cents per month)."
echo "If you enabled GuardDuty / Security Hub / Inspector, they were turned off with the infra destroy."
