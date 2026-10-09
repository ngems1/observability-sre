#!/usr/bin/env bash
# Shared settings for the AWS scripts. Designed for AWS CloudShell (us-east-1):
# it is already logged in as your console identity, has the AWS CLI, git and Docker.
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$HOME/bin:$PATH"

# CloudShell keeps only 1 GB in $HOME. Terraform providers (~600 MB) and .terraform dirs
# go to /tmp (lost when the session recycles; `terraform init` simply re-downloads them).
export TF_PLUGIN_CACHE_DIR="/tmp/tf-plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
export TF_IN_AUTOMATION=1

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_BUCKET="opsdesk-tfstate-${ACCOUNT_ID}-${AWS_REGION}"
export TF_VAR_state_bucket="${TF_VAR_state_bucket:-$STATE_BUCKET}"  # platform root reads infra state from here
CLUSTER_NAME="opsdesk"   # one shared cluster; dev and prod are namespaces in it
# Which application environment a script acts on: APP_ENV=dev (default) or APP_ENV=prod
APP_ENV="${APP_ENV:-dev}"
case "$APP_ENV" in dev|prod) ;; *) echo "APP_ENV must be dev or prod (got '$APP_ENV')" >&2; exit 1 ;; esac
APP_NS="opsdesk-${APP_ENV}"
export APP_ENV APP_NS

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# tf <root> <args...>  -- runs terraform in terraform/<root> with its data dir under /tmp
tf() {
  local root="$1"; shift
  TF_DATA_DIR="/tmp/tf-data/${root}" terraform -chdir="$ROOT/terraform/${root}" "$@"
}

tf_init() {
  local root="$1"
  if [[ "$root" == "bootstrap" ]]; then
    tf bootstrap init -input=false -upgrade=false
  else
    tf "$root" init -input=false -reconfigure -backend-config="bucket=${STATE_BUCKET}"
  fi
}

# init only if this CloudShell session has not initialised the root yet
ensure_init() {
  [[ -d "/tmp/tf-data/$1" ]] || tf_init "$1" >/dev/null
}

# In GitHub Actions the variables come from TF_VAR_* (repository variables), not tfvars files
require_tfvars() {
  local root="$1"
  [[ "${CI:-}" == "true" ]] && return 0
  [[ -f "$ROOT/terraform/${root}/terraform.tfvars" ]] || \
    die "terraform/${root}/terraform.tfvars is missing: copy terraform.tfvars.example and fill it in"
}

kubeconfig() {
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null
}
