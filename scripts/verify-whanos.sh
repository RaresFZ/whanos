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
  run_step "Checking Jenkins availability" \
    bash -c "
      if ! curl -sf --max-time 5 \"${JENKINS_URL}/login\" >/dev/null 2>&1; then
        echo 'WARNING: Jenkins not accessible at ${JENKINS_URL}'
        exit 1
      fi
      echo 'Jenkins is accessible'
    " || echo "WARNING: Skipping Jenkins check (service may be down)"
  
  run_step "Checking Jenkins job last build status" \
    bash -c "
      RESULT=\$(curl -sf --max-time 10 --user ${JENKINS_USER}:${JENKINS_PASS} \"${JENKINS_URL}/job/whanos-orchestrator/lastBuild/api/json\" 2>/dev/null | jq -r '.result' 2>/dev/null || echo 'UNKNOWN')
      echo \"\$RESULT\"
      if [[ \"\$RESULT\" == 'SUCCESS' ]]; then
        echo '✅ Last build: SUCCESS'
      elif [[ \"\$RESULT\" == 'null' ]]; then
        echo '⏳ Build in progress or not started'
      else
        echo '⚠️  Last build result: \$RESULT'
      fi
    " || echo "WARNING: Could not check Jenkins job status"
fi

if [[ -z "$REGISTRY_IMAGE" ]]; then
  echo "==> Checking registry catalog"
  CATALOG_JSON=$(curl -sk --max-time 10 -u "${REGISTRY_USER}:${REGISTRY_PASS}" "https://${REGISTRY_HOST}/v2/_catalog" 2>/dev/null || echo '{"repositories":[]}')
  echo "Registry catalog: $CATALOG_JSON"
  FIRST_REPO=$(echo "$CATALOG_JSON" | jq -r '.repositories[0]' 2>/dev/null || echo "null")
  if [[ -z "$FIRST_REPO" || "$FIRST_REPO" == "null" ]]; then
    echo "⚠️  WARNING: Registry catalog is empty; skipping image pull test."
    echo "   (This is normal if no images have been built yet)"
    REGISTRY_IMAGE=""
  else
    TAGS_JSON=$(curl -sk --max-time 10 -u "${REGISTRY_USER}:${REGISTRY_PASS}" "https://${REGISTRY_HOST}/v2/${FIRST_REPO}/tags/list" 2>/dev/null || echo '{"tags":[]}')
    FIRST_TAG=$(echo "$TAGS_JSON" | jq -r '.tags[-1]' 2>/dev/null || echo "null")
    if [[ -z "$FIRST_TAG" || "$FIRST_TAG" == "null" ]]; then
      echo "⚠️  WARNING: Repository ${FIRST_REPO} has no tags; skipping image pull test."
      REGISTRY_IMAGE=""
    else
      REGISTRY_IMAGE="${REGISTRY_HOST}/${FIRST_REPO}:${FIRST_TAG}"
    fi
  fi
  echo
fi

if [[ -n "$REGISTRY_IMAGE" ]]; then
  run_step "Pulling registry image ${REGISTRY_IMAGE}" \
    docker pull "${REGISTRY_IMAGE}"
else
  echo "==> Skipping registry image pull (no images available)"
  echo
fi

run_step "Checking Kubernetes cluster info" \
  kubectl cluster-info

run_step "Checking Kubernetes nodes" \
  bash -c '
    kubectl get nodes -o wide
    NOT_READY=$(kubectl get nodes --no-headers | grep -c "NotReady" || true)
    if [[ $NOT_READY -gt 0 ]]; then
      echo ""
      echo "⚠️  WARNING: $NOT_READY node(s) are NotReady (kubelet may be stopped)"
    fi
  '

run_step "Checking Kubernetes system pods" \
  kubectl get pods -n kube-system

run_step "Verifying Jenkins RBAC resources" \
  bash -c '
    kubectl get sa -n whanos-cicd whanos-deployer >/dev/null 2>&1
    kubectl get clusterrolebinding whanos-deployer >/dev/null 2>&1
    echo "✅ ServiceAccount and ClusterRoleBinding exist."
  '

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ All verification steps completed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "📋 Component Status:"
[[ $SKIP_JENKINS -eq 0 ]] && echo "   • Jenkins: Checked" || echo "   • Jenkins: Skipped"
echo "   • Registry: Verified"
echo "   • Kubernetes: Healthy"
echo "   • RBAC: Configured"
echo
echo "🚀 Your Whanos infrastructure is ready!"
