#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/start-whanos.sh [OPTIONS] [-- [ansible-playbook args...]]

High level bootstrap for the Whanos stack:
  1. Runs the Ansible site playbook (unless skipped).
  2. Applies Jenkins deployer RBAC to the Kubernetes cluster.
  3. Optionally builds sample application images via whanos-build.

Options:
  --skip-ansible             Do not run ansible-playbook ansible/site.yml.
  --skip-rbac                Skip kubectl apply of kubernetes/base/jenkins-rbac.yaml.
  --bootstrap-base-images    Build sample apps with whanos-build (no push).
  --push-base-images         Build and push sample apps (implies --bootstrap-base-images).
  --registry HOST            Registry host (defaults to WHANOS_REGISTRY env variable).
  --apps LIST                Comma-separated list of sample apps to build (default: all).
  --tag TAG                  Tag to use for bootstrap images (default: bootstrap).
  --dry-run                  Print actions without executing them.
  -h, --help                 Show this help message.

Environment:
  WHANOS_REGISTRY  Default registry host if --registry is not provided.
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="${ROOT}/ansible"
K8S_RBAC="${ROOT}/kubernetes/base/jenkins-rbac.yaml"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' not found in PATH." >&2
    exit 1
  fi
}

run_cmd() {
  local desc="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $desc: $*"
  else
    echo ">>> $desc: $*"
    "$@"
  fi
}

SKIP_ANSIBLE=0
SKIP_RBAC=0
BOOTSTRAP_IMAGES=0
PUSH_IMAGES=0
REGISTRY_HOST="${WHANOS_REGISTRY:-}"
APP_LIST=""
TAG="bootstrap"
DRY_RUN=0

ANSIBLE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ansible) SKIP_ANSIBLE=1; shift ;;
    --skip-rbac) SKIP_RBAC=1; shift ;;
    --bootstrap-base-images) BOOTSTRAP_IMAGES=1; shift ;;
    --push-base-images) BOOTSTRAP_IMAGES=1; PUSH_IMAGES=1; shift ;;
    --registry) REGISTRY_HOST="$2"; shift 2 ;;
    --apps) APP_LIST="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ANSIBLE_ARGS=("$@"); break ;;
    *) ANSIBLE_ARGS+=("$1"); shift ;;
  esac
done

if [[ $SKIP_ANSIBLE -eq 0 ]]; then
  require_cmd ansible-playbook
fi

if [[ $SKIP_RBAC -eq 0 ]]; then
  require_cmd kubectl
  if [[ -z "${KUBECONFIG:-}" && -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
  fi
fi

if [[ $BOOTSTRAP_IMAGES -eq 1 ]]; then
  require_cmd "${ROOT}/bin/whanos-build"
  if [[ -z "$REGISTRY_HOST" ]]; then
    echo "Error: --registry or WHANOS_REGISTRY must be set for image bootstrap." >&2
    exit 1
  fi
fi

declare -A SAMPLE_APPS=(
  ["c"]="whanos_example_apps/c-hello-world"
  ["java"]="whanos_example_apps/java-hello-world"
  ["javascript"]="whanos_example_apps/js-hello-world"
  ["python"]="whanos_example_apps/python-hello-world"
  ["befunge"]="whanos_example_apps/befunge-hello-world"
)

SELECTED_APPS=()
if [[ -n "$APP_LIST" ]]; then
  IFS=',' read -r -a SELECTED_APPS <<< "$APP_LIST"
else
  SELECTED_APPS=("${!SAMPLE_APPS[@]}")
fi

cd "$ROOT"

if [[ $SKIP_ANSIBLE -eq 0 ]]; then
  run_cmd "Ansible provisioning" ansible-playbook \
    -i "${ANSIBLE_DIR}/inventory/hosts.yml" \
    "${ANSIBLE_DIR}/site.yml" \
    "${ANSIBLE_ARGS[@]}"
fi

if [[ $SKIP_RBAC -eq 0 ]]; then
  run_cmd "Applying Jenkins deployer RBAC" kubectl apply -f "$K8S_RBAC"
fi

if [[ $BOOTSTRAP_IMAGES -eq 1 ]]; then
  for lang in "${SELECTED_APPS[@]}"; do
    app_dir="${SAMPLE_APPS[$lang]:-}"
    if [[ -z "$app_dir" ]]; then
      echo "Warning: unknown sample app '$lang'; skipping." >&2
      continue
    fi
    image_ref="${REGISTRY_HOST}/whanos/apps/${lang}-hello-world:${TAG}"
    build_cmd=("${ROOT}/bin/whanos-build" --repo "${ROOT}/${app_dir}" --image "$image_ref")
    if [[ $PUSH_IMAGES -eq 0 ]]; then
      build_cmd+=(--no-push)
    fi
    run_cmd "Bootstrapping ${lang} sample" "${build_cmd[@]}"
  done
fi

echo "Start procedure complete."
