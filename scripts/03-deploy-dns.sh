#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dns-lab"
SERVICE_NAME="coredns"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed." >&2; exit 1; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying CoreDNS demo service in namespace '$NAMESPACE'..."
cat <<'EOF' | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-config
data:
  Corefile: |
    .:53 {
        hosts {
            10.10.10.10 app.example.local
            10.10.10.20 api.example.local
            fallthrough
        }
        log
        errors
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: coredns
  template:
    metadata:
      labels:
        app: coredns
    spec:
      containers:
      - name: coredns
        image: coredns/coredns:1.11.1
        imagePullPolicy: IfNotPresent
        args:
        - -conf
        - /etc/coredns/Corefile
        ports:
        - name: dns-udp
          containerPort: 53
          protocol: UDP
        - name: dns-tcp
          containerPort: 53
          protocol: TCP
        volumeMounts:
        - name: config-volume
          mountPath: /etc/coredns
      volumes:
      - name: config-volume
        configMap:
          name: coredns-config
---
apiVersion: v1
kind: Service
metadata:
  name: coredns
spec:
  type: ClusterIP
  selector:
    app: coredns
  ports:
  - name: dns-udp
    port: 53
    targetPort: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    targetPort: 53
    protocol: TCP
EOF

kubectl -n "$NAMESPACE" rollout status deployment "$SERVICE_NAME" --timeout=300s

if kubectl get crd transportservers.k8s.nginx.org >/dev/null 2>&1; then
  echo "Applying NGINX TransportServer resources..."
  kubectl apply -f "$(dirname "$0")/../dns-transportservers.yaml"
else
  echo "TransportServer CRD not found. Run scripts/02-install-ingress-nginx.sh before applying DNS TransportServers." >&2
  exit 1
fi

echo "CoreDNS demo and TransportServers deployed."
