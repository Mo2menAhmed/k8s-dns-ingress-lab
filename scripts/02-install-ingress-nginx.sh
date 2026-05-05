#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="nginx-ingress"
RELEASE_NAME="nginx-ingress"
CHART="oci://ghcr.io/nginx/charts/nginx-ingress"
CHART_VERSION="2.5.1"
VALUES_FILE="$(dirname "$0")/../nginx-plus-dns-values.yaml"
LICENSE_FILE="${LICENSE_FILE:-$(dirname "$0")/../license.jwt}"
LICENSE_SECRET="nplus-license"
REGISTRY_SECRET="regcred"

command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed." >&2; exit 1; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [ -f "$LICENSE_FILE" ]; then
  echo "Creating NGINX Plus license and registry secrets from $LICENSE_FILE..."
  kubectl -n "$NAMESPACE" create secret generic "$LICENSE_SECRET" \
    --from-file=license.jwt="$LICENSE_FILE" \
    --type=nginx.com/license \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$NAMESPACE" create secret docker-registry "$REGISTRY_SECRET" \
    --docker-server=private-registry.nginx.com \
    --docker-username="$(cat "$LICENSE_FILE")" \
    --docker-password=none \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "No local license file found at $LICENSE_FILE."
  echo "Checking for existing Kubernetes secrets '$LICENSE_SECRET' and '$REGISTRY_SECRET'..."
  kubectl -n "$NAMESPACE" get secret "$LICENSE_SECRET" >/dev/null
  kubectl -n "$NAMESPACE" get secret "$REGISTRY_SECRET" >/dev/null
fi

echo "Installing or upgrading F5 NGINX Ingress Controller with NGINX Plus..."
helm upgrade --install "$RELEASE_NAME" "$CHART" \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE"

echo "Waiting for NGINX Plus ingress controller pod to be ready..."
kubectl -n "$NAMESPACE" wait \
  --for=condition=Ready pod \
  -l app.kubernetes.io/name=nginx-ingress \
  --timeout=600s

echo "NGINX Plus ingress controller installed successfully."
