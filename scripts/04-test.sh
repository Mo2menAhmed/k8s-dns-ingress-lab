#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
PORT=53

command -v dig >/dev/null 2>&1 || { echo "dig is required but not installed. Install dnsutils or bind-tools." >&2; exit 1; }
command -v ss >/dev/null 2>&1 || { echo "ss is required but not installed." >&2; exit 1; }

CLUSTER_NAME="dns-ingress-lab"
if ! ss -tuln | grep -qE "(^|[:.])${PORT}( |$)"; then
  if command -v docker >/dev/null 2>&1; then
    INSPECT_PORT=$(docker inspect --format='{{with index .NetworkSettings.Ports "53/tcp"}}{{(index . 0).HostPort}}{{end}}' "${CLUSTER_NAME}-control-plane" 2>/dev/null || true)
    if [ -n "${INSPECT_PORT:-}" ]; then
      PORT="$INSPECT_PORT"
      echo "Port 53 is not listening locally; using kind mapped host port $PORT."
    else
      echo "Port 53 is not listening locally and no kind port mapping was found." >&2
      exit 1
    fi
  else
    echo "Port 53 is not listening locally and docker is unavailable for port mapping inspection." >&2
    exit 1
  fi
fi

echo "Querying DNS via the ingress controller at ${HOST}:${PORT}..."

echo "Testing app.example.local (UDP)..."
dig @"$HOST" -p "$PORT" +short app.example.local

echo "Testing api.example.local (UDP)..."
dig @"$HOST" -p "$PORT" +short api.example.local

echo "Testing app.example.local (TCP)..."
dig @"$HOST" -p "$PORT" +tcp +short app.example.local

echo "Testing api.example.local (TCP)..."
dig @"$HOST" -p "$PORT" +tcp +short api.example.local

echo "All DNS tests completed."
