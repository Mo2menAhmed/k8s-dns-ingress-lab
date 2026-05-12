#!/usr/bin/env bash
set -euo pipefail

# LAB ONLY rollback helper.
# This does not modify TCP TransportServer resources.
# This does not change TCP, listener port 53, or backend service dns-lab/coredns:53.

echo "== Current resources before rollback =="
kubectl get transportserver dns-udp -n dns-lab -o yaml || true
helm get values nginx-ingress -n nginx-ingress -o yaml || true
kubectl get pods -n nginx-ingress -o wide || true

echo
echo "== Reapplying previous UDP TransportServer without serverSnippets =="
kubectl apply -f - <<'YAML'
apiVersion: k8s.nginx.org/v1
kind: TransportServer
metadata:
  name: dns-udp
  namespace: dns-lab
spec:
  ingressClassName: nginx
  listener:
    name: dns-udp
    protocol: UDP
  upstreams:
  - name: dns
    service: coredns
    port: 53
  upstreamParameters:
    udpRequests: 1
    udpResponses: 1
  action:
    pass: dns
YAML

echo
echo "== Explicitly cleaning node routing rules from DaemonSet pods =="
if kubectl -n kube-system get daemonset udp-transparent-routing-lab >/dev/null 2>&1; then
  for pod in $(kubectl -n kube-system get pods -l app=udp-transparent-routing-lab -o name); do
    echo "Cleaning via $pod"
    kubectl -n kube-system exec "$pod" -- /bin/bash /opt/transparent-routing/transparent-routing.sh cleanup || true
  done
fi

echo
echo "== Deleting lab-only routing DaemonSet and ConfigMap =="
kubectl delete -f node-transparent-routing-daemonset.yaml --ignore-not-found=true

cat <<'MSG'

== Remove Helm values added only for this test ==

If values-transparent-lab.yaml was added only for this transparent UDP test,
upgrade the controller again without that overlay, for example:

  helm upgrade nginx-ingress oci://ghcr.io/nginx/charts/nginx-ingress \
    --version 2.5.1 \
    --namespace nginx-ingress \
    -f nginx-plus-dns-values.yaml

Then wait for the controller:

  kubectl -n nginx-ingress rollout status daemonset/nginx-ingress-controller --timeout=300s

If the DaemonSet name differs, list it with:

  kubectl -n nginx-ingress get daemonset
MSG

echo
echo "== Post-rollback checks =="
kubectl describe transportserver dns-udp -n dns-lab || true
kubectl -n nginx-ingress get pods -o wide || true
