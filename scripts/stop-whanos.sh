#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/stop-whanos.sh [OPTIONS]

Gracefully stops Whanos infrastructure components via Ansible ad-hoc commands.

Options:
  --skip-jenkins        Do not stop/disable the Jenkins service.
  --skip-registry       Do not stop the Docker registry stack.
  --skip-k8s            Do not stop Kubernetes services (kubelet). Note: containerd is left running for Docker.
  --reset-k8s           Run 'kubeadm reset -f' on all Kubernetes nodes and stop containerd (destructive).
  --purge-registry-data Remove registry data directory after stopping (requires --purge-registry-data).
  --dry-run             Print commands instead of executing them.
  -h, --help            Show this help.

Assumptions:
  - Jenkins systemd service is named 'jenkins'.
  - Registry docker-compose lives at /srv/registry/docker-compose.yml.
  - Registry data resides in /srv/registry/data (for purge).
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${ROOT}/ansible/inventory/hosts.yml"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command '$1' not found." >&2
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

SKIP_JENKINS=0
SKIP_REGISTRY=0
SKIP_K8S=0
RESET_K8S=0
PURGE_REG_DATA=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-jenkins) SKIP_JENKINS=1; shift ;;
    --skip-registry) SKIP_REGISTRY=1; shift ;;
    --skip-k8s) SKIP_K8S=1; shift ;;
    --reset-k8s) RESET_K8S=1; shift ;;
    --purge-registry-data) PURGE_REG_DATA=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

require_cmd ansible

if [[ $SKIP_JENKINS -eq 0 ]]; then
  run_cmd "Stopping Jenkins service" ansible \
    -i "$INVENTORY" \
    jenkins \
    -b \
    -m ansible.builtin.service \
    -a "name=jenkins state=stopped enabled=no"
fi

if [[ $SKIP_REGISTRY -eq 0 ]]; then
  run_cmd "Stopping registry docker compose stack" ansible \
    -i "$INVENTORY" \
    registry \
    -b \
    -m ansible.builtin.shell \
    -a "set -euo pipefail && docker compose -f /srv/registry/docker-compose.yml down"

  if [[ $PURGE_REG_DATA -eq 1 ]]; then
    run_cmd "Purging registry data directory" ansible \
      -i "$INVENTORY" \
      registry \
      -b \
      -m ansible.builtin.file \
      -a "path=/srv/registry/data state=absent"
  fi
fi

if [[ $SKIP_K8S -eq 0 ]]; then
  run_cmd "Stopping kubelet service" ansible \
    -i "$INVENTORY" \
    k8s_control_plane:k8s_workers \
    -b \
    -m ansible.builtin.service \
    -a "name=kubelet state=stopped"

  run_cmd "Waiting for pods to terminate" ansible \
    -i "$INVENTORY" \
    k8s_control_plane:k8s_workers \
    -b \
    -m ansible.builtin.shell \
    -a "sleep 5"

  run_cmd "Stopping all remaining Kubernetes containers" ansible \
    -i "$INVENTORY" \
    k8s_control_plane:k8s_workers \
    -b \
    -m ansible.builtin.shell \
    -a "crictl --runtime-endpoint unix:///run/containerd/containerd.sock stop \$(crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -q 2>/dev/null) 2>/dev/null || true"

  run_cmd "Disabling kubelet service" ansible \
    -i "$INVENTORY" \
    k8s_control_plane:k8s_workers \
    -b \
    -m ansible.builtin.service \
    -a "name=kubelet enabled=no"

  echo "Note: containerd is left running for Docker (registry). Use --reset-k8s to fully reset."
fi

if [[ $RESET_K8S -eq 1 ]]; then
  run_cmd "Stopping kubelet (for reset)" ansible \
    -i "$INVENTORY" \
    k8s_control_plane:k8s_workers \
    -b \
    -m ansible.builtin.service \
    -a "name=kubelet state=stopped enabled=no"

  run_cmd "Stopping containerd (for reset)" ansible \
    -i "$INVENTORY" \
    k8s_control_plane:k8s_workers \
    -b \
    -m ansible.builtin.service \
    -a "name=containerd state=stopped enabled=no"

  run_cmd "Resetting Kubernetes workers" ansible \
    -i "$INVENTORY" \
    k8s_workers \
    -b \
    -m ansible.builtin.shell \
    -a "kubeadm reset -f"

  run_cmd "Resetting Kubernetes control plane" ansible \
    -i "$INVENTORY" \
    k8s_control_plane \
    -b \
    -m ansible.builtin.shell \
    -a "kubeadm reset -f && rm -rf /etc/kubernetes ~/.kube"
fi

echo "Stop procedure complete."
