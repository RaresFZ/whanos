#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-whanos.sh [OPTIONS]

Runs end-to-end checks to confirm the Whanos stack is healthy.

Checks:
  1. Jenkins pipeline status (optional)
  2. Registry availability and image pull
  3. Kubernetes cluster health and RBAC

Options:
  --skip-jenkins     Skip Jenkins API check.
  --reg-image IMAGE  Registry image reference to pull (default: auto-detect from catalog).
  --kubeconfig PATH  Path to kubeconfig (default: $KUBECONFIG or ~/.kube/config or /etc/kubernetes/admin.conf).
  --registry URL     Override registry host (default: registry.whanos.example.com).
  --user USER        Registry username (default: ci).
  --password PASS    Registry password (default: changeme).
  -h, --help         Show this help message.
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' not found in PATH." >&2
    exit 1
  fi
}

run_step() {
  local desc="$1"; shift
  echo "==> $desc"
  "$@"
  echo
}

JENKINS_URL="http://localhost:8080"
JENKINS_USER="admin"
JENKINS_PASS="changeme"
REGISTRY_HOST="registry.whanos.example.com"
REGISTRY_USER="ci"
REGISTRY_PASS="changeme"
REGISTRY_IMAGE=""
SKIP_JENKINS=0
KUBECONFIG_PATH="${KUBECONFIG:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-jenkins) SKIP_JENKINS=1; shift ;;
    --reg-image) REGISTRY_IMAGE="$2"; shift 2 ;;
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --registry) REGISTRY_HOST="$2"; shift 2 ;;
    --user) REGISTRY_USER="$2"; shift 2 ;;
    --password) REGISTRY_PASS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

require_cmd curl
require_cmd docker
require_cmd kubectl

if [[ -z "$KUBECONFIG_PATH" ]]; then
  if [[ -f "$HOME/.kube/config" ]]; then
    KUBECONFIG_PATH="$HOME/.kube/config"
  elif [[ -r /etc/kubernetes/admin.conf ]]; then
    KUBECONFIG_PATH="/etc/kubernetes/admin.conf"
  fi
fi

if [[ -z "$KUBECONFIG_PATH" ]]; then
  echo "Error: no kubeconfig found. Set --kubeconfig or ensure ~/.kube/config exists." >&2
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_PATH"

if [[ $SKIP_JENKINS -eq 0 ]]; then
  run_step "Checking Jenkins job last build status" \
    bash -c "
      curl -sf --user ${JENKINS_USER}:${JENKINS_PASS} \"${JENKINS_URL}/job/whanos-orchestrator/lastBuild/api/json\" \
        | jq -r '.result' \
        | grep -E 'SUCCESS|null'
    "
fi

if [[ -z "$REGISTRY_IMAGE" ]]; then
  CATALOG_JSON=$(curl -sk -u "${REGISTRY_USER}:${REGISTRY_PASS}" "https://${REGISTRY_HOST}/v2/_catalog")
  echo "Registry catalog: $CATALOG_JSON"
  FIRST_REPO=$(echo "$CATALOG_JSON" | jq -r '.repositories[0]')
  if [[ -z "$FIRST_REPO" || "$FIRST_REPO" == "null" ]]; then
    echo "Error: registry catalog empty; set --reg-image manually." >&2
    exit 1
  fi
  TAGS_JSON=$(curl -sk -u "${REGISTRY_USER}:${REGISTRY_PASS}" "https://${REGISTRY_HOST}/v2/${FIRST_REPO}/tags/list")
  FIRST_TAG=$(echo "$TAGS_JSON" | jq -r '.tags[-1]')
  if [[ -z "$FIRST_TAG" || "$FIRST_TAG" == "null" ]]; then
    echo "Error: repository ${FIRST_REPO} has no tags; set --reg-image manually." >&2
    exit 1
  fi
  REGISTRY_IMAGE="${REGISTRY_HOST}/${FIRST_REPO}:${FIRST_TAG}"
fi

run_step "Pulling registry image ${REGISTRY_IMAGE}" \
  docker pull "${REGISTRY_IMAGE}"

run_step "Checking Kubernetes cluster info" \
  kubectl cluster-info

run_step "Checking Kubernetes nodes" \
  kubectl get nodes -o wide

run_step "Checking Kubernetes system pods" \
  kubectl get pods -n kube-system

run_step "Verifying Jenkins RBAC resources" \
  bash -c '
    kubectl get sa -n whanos-cicd whanos-deployer >/dev/null
    kubectl get clusterrolebinding whanos-deployer >/dev/null
    echo "ServiceAccount and ClusterRoleBinding exist."
  '

echo "All verification steps completed successfully."
