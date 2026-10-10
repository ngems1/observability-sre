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
  step "Uninstall the app in every environment (removes their Ingresses)"
  for ns in opsdesk-dev opsdesk-prod; do
    kubectl -n "$ns" delete deploy k6-load --ignore-not-found 2>/dev/null || true
    helm uninstall opsdesk -n "$ns" --wait 2>/dev/null || true
  done
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

# Everything the AWS Load Balancer Controller creates - ALBs, their target groups, their security groups
# and the network interfaces in the public subnets - lives OUTSIDE Terraform state. The block above only
# runs while the cluster still exists, so a destroy that failed partway (cluster gone, VPC left) skips it
# and every retry fails the same way on DependencyViolation. This runs unconditionally and by VPC, so a
# retry cleans up what the first attempt orphaned.
step "Remove what the cluster left behind in the VPC"
VPC_ID="$(aws ec2 describe-vpcs --filters Name=tag:Project,Values=opsdesk \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo None)"

if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  echo "No OpsDesk VPC found - nothing to clean up."
else
  echo "VPC: $VPC_ID"

  for arn in $(aws elbv2 describe-load-balancers \
      --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
    echo "  deleting load balancer $arn"
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" 2>/dev/null || true
  done
  for arn in $(aws elbv2 describe-target-groups \
      --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null); do
    aws elbv2 delete-target-group --target-group-arn "$arn" 2>/dev/null || true
  done

  # Interfaces of a deleted load balancer disappear a minute or two later; ones left "available"
  # are detached and never go on their own, so delete those explicitly.
  for _ in $(seq 1 30); do
    left="$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)"
    [[ "$left" == "0" ]] && break
    echo "  $left network interface(s) still in the VPC..."
    for eni in $(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
      aws ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || true
    done
    sleep 10
  done

  # Twice: security groups that reference each other refuse to go on the first pass.
  for _ in 1 2; do
    for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
      aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
    done
  done
fi

step "Destroy the infrastructure"
tf_init infra
if ! tf infra destroy -input=false -auto-approve; then
  warn "infra destroy failed. Still holding the VPC:"
  if [[ "$VPC_ID" != "None" && -n "$VPC_ID" ]]; then
    aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'NetworkInterfaces[].{ENI:NetworkInterfaceId,Status:Status,Desc:Description}' \
      --output table || true
    aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerName" \
      --output table || true
    aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "SecurityGroups[?GroupName!='default'].{SG:GroupId,Name:GroupName}" --output table || true
  fi
  die "VPC still has dependencies - the tables above name them. Re-running Destroy now also retries the cleanup above."
fi

step "Leftover check"
aws ec2 describe-volumes --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=observability \
  --query 'Volumes[].VolumeId' --output text || true
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text || true
echo "Done. The state bucket ${STATE_BUCKET} is kept (a few cents per month)."
echo "If you enabled GuardDuty / Security Hub / Inspector, they were turned off with the infra destroy."
