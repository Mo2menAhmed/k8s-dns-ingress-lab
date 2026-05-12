#!/usr/bin/env bash
set -euo pipefail

# Validation/test helper for UDP transparent proxying in this
# k8s-dns-ingress-lab repo.
# Default behavior is safe: print current state and run server-side dry-run.
# Set APPLY_CHANGES=true to apply node routing and the UDP TransportServer.

APPLY_CHANGES="${APPLY_CHANGES:-false}"
NODE_IP="${NODE_IP:-127.0.0.1}"
DNS_PORT="${DNS_PORT:-53}"

echo "== Current resources before applying anything =="
kubectl get transportserver dns-udp -n dns-lab -o yaml
helm get values nginx-ingress -n nginx-ingress -o yaml
kubectl get pods -n nginx-ingress -o wide

echo
echo "== Server-side validation of UDP TransportServer =="
kubectl apply --dry-run=server -f dns-udp-transparent-transportserver.yaml

if [ "$APPLY_CHANGES" != "true" ]; then
  cat <<'MSG'

Dry-run complete. No changes were applied.

To apply this transparent UDP profile:

  APPLY_CHANGES=true NODE_IP=127.0.0.1 ./test-commands.sh

The script will:
- apply node-transparent-routing-daemonset.yaml
- apply dns-udp-transparent-transportserver.yaml
- verify TransportServer status
- verify generated NGINX stream config contains:
  proxy_bind $remote_addr transparent;
- run dig against NODE_IP on port 53
MSG
  exit 0
fi

echo
echo "== Applying node routing DaemonSet =="
kubectl apply -f node-transparent-routing-daemonset.yaml
kubectl -n kube-system rollout status daemonset/udp-transparent-routing-lab --timeout=180s

echo
echo "== Applying UDP TransportServer transparent proxy snippet =="
kubectl apply -f dns-udp-transparent-transportserver.yaml

echo
echo "== Describing UDP TransportServer =="
kubectl describe transportserver dns-udp -n dns-lab

echo
echo "== Recent NGINX Ingress Controller logs =="
kubectl logs -n nginx-ingress -l app.kubernetes.io/name=nginx-ingress --tail=200

echo
echo "== Verify generated NGINX stream config contains proxy_bind transparent =="
NGINX_POD="$(kubectl -n nginx-ingress get pod -l app.kubernetes.io/name=nginx-ingress -o jsonpath='{.items[0].metadata.name}')"
kubectl -n nginx-ingress exec "$NGINX_POD" -- sh -c "nginx -T 2>/dev/null | grep -F 'proxy_bind \$remote_addr transparent;'"

echo
echo "== Verify node routing rules =="
ROUTING_POD="$(kubectl -n kube-system get pod -l app=udp-transparent-routing-lab -o jsonpath='{.items[0].metadata.name}')"
kubectl -n kube-system exec "$ROUTING_POD" -- sh -c 'iptables -t mangle -S | grep udp-transparent-dns-lab'
kubectl -n kube-system exec "$ROUTING_POD" -- sh -c 'ip rule show | grep "lookup 100"'
kubectl -n kube-system exec "$ROUTING_POD" -- sh -c 'ip route show table 100'

cat <<'MSG'

== Packet capture command ==

In another terminal, capture on the backend pod if tcpdump is available:

  BACKEND_POD=$(kubectl -n dns-lab get pod -l app=coredns -o jsonpath='{.items[0].metadata.name}')
  kubectl -n dns-lab exec -it "$BACKEND_POD" -- tcpdump -ni any udp port 53

If the backend image does not include tcpdump, capture from the lab routing
DaemonSet pod, which runs on hostNetwork:

  ROUTING_POD=$(kubectl -n kube-system get pod -l app=udp-transparent-routing-lab -o jsonpath='{.items[0].metadata.name}')
  kubectl -n kube-system exec -it "$ROUTING_POD" -- tcpdump -ni any udp port 53
MSG

echo
echo "== DNS test from this shell =="
dig @"$NODE_IP" -p "$DNS_PORT" app.example.local +short +time=2 +tries=1
dig @"$NODE_IP" -p "$DNS_PORT" api.example.local +short +time=2 +tries=1

cat <<MSG

Expected:
- app.example.local resolves to 10.10.10.10.
- api.example.local resolves to 10.10.10.20.
- Backend-side tcpdump shows the original client IP as source only if transparent
  routing is correct.
- If DNS times out, assume return-path routing is wrong and run rollback.

To test from a separate client inside the lab subnet:

  dig @<NODE_IP> -p ${DNS_PORT} app.example.local +short
  dig @<NODE_IP> -p ${DNS_PORT} api.example.local +short
MSG
