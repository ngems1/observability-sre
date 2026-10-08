#!/usr/bin/env bash
# Install Terraform, Helm and kubectl into ~/bin (persists across CloudShell sessions).
#   bash scripts/aws/setup-cloudshell.sh
set -euo pipefail

TF_VERSION="${TF_VERSION:-1.12.2}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.35.0}"   # match the EKS minor version (+/- 1)
mkdir -p "$HOME/bin"
export PATH="$HOME/bin:$PATH"
cd /tmp

if ! command -v terraform >/dev/null || [[ "$(terraform version -json | python3 -c 'import sys,json;print(json.load(sys.stdin)["terraform_version"])')" != "$TF_VERSION" ]]; then
  echo "Installing Terraform $TF_VERSION"
  curl -fsSLo terraform.zip "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip"
  unzip -o -q terraform.zip terraform && mv terraform "$HOME/bin/" && rm terraform.zip
fi

if ! command -v helm >/dev/null; then
  echo "Installing Helm 3"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | \
    HELM_INSTALL_DIR="$HOME/bin" USE_SUDO=false bash
fi

if ! command -v kubectl >/dev/null; then
  echo "Installing kubectl $KUBECTL_VERSION"
  curl -fsSLo "$HOME/bin/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  chmod +x "$HOME/bin/kubectl"
fi

grep -q 'HOME/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"

echo
aws sts get-caller-identity --query Arn --output text
terraform version | head -1
helm version --short
kubectl version --client | head -1
docker version --format 'docker {{.Server.Version}}' 2>/dev/null || echo "docker: not available in this CloudShell session"
echo "Ready. Next (once): terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply"
