#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="dns-ingress-lab"
HOST_PORT="53"
NODE_PORT="53"
LISTEN_ADDRESS="127.0.0.1"
KIND_CONFIG="$(dirname "$0")/../kind-config.yaml"

command -v docker >/dev/null 2>&1 || { echo "docker is required but not installed." >&2; exit 1; }
command -v kind >/dev/null 2>&1 || { echo "kind is required but not installed." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed." >&2; exit 1; }

docker info >/dev/null 2>&1 || {
  echo "Failed to connect to Docker. Ensure Docker Desktop is running, WSL2 integration is enabled, and your user can access /var/run/docker.sock." >&2
  echo "If you see a permissions error, try adding your WSL user to the docker group:" >&2
  echo "  sudo usermod -aG docker \$USER && newgrp docker" >&2
  exit 1
}

if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists."
  if docker inspect --format='{{with index .NetworkSettings.Ports "53/tcp"}}{{(index . 0).HostPort}}{{end}}' "$CLUSTER_NAME-control-plane" >/dev/null 2>&1; then
    EXISTING_HOST_PORT=$(docker inspect --format='{{with index .NetworkSettings.Ports "53/tcp"}}{{(index . 0).HostPort}}{{end}}' "$CLUSTER_NAME-control-plane")
    if [ -n "${EXISTING_HOST_PORT:-}" ] && [ "$EXISTING_HOST_PORT" != "$HOST_PORT" ]; then
      echo "Existing cluster '$CLUSTER_NAME' maps node port $NODE_PORT to host TCP port $EXISTING_HOST_PORT, not $HOST_PORT." >&2
      echo "Use kind delete cluster --name $CLUSTER_NAME to remove the cluster, then rerun bash scripts/01-create-cluster.sh." >&2
      exit 1
    fi
  fi
  echo "Skipping cluster creation."
  exit 0
fi

LISTEN_ADDRESS_RE="${LISTEN_ADDRESS//./\\.}"
if ss -tuln | grep -qE "(^|[[:space:]])${LISTEN_ADDRESS_RE}:${HOST_PORT}([[:space:]]|$)"; then
  echo "Host port ${LISTEN_ADDRESS}:${HOST_PORT} is already in use. kind cannot publish DNS there." >&2
  echo "Stop the process using ${LISTEN_ADDRESS}:${HOST_PORT}, or choose a different hostPort in kind-config.yaml and scripts/04-test.sh." >&2
  exit 1
fi

echo "Creating kind cluster '$CLUSTER_NAME'..."
kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"

echo "Waiting for control plane node to be ready..."
kubectl wait --for=condition=Ready node/dns-ingress-lab-control-plane --timeout=120s

echo "Kind cluster '$CLUSTER_NAME' created successfully."
