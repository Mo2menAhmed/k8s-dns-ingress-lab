# LAB ONLY: UDP Transparent Proxying for DNS TransportServer

This is a safe lab-only test plan for UDP transparent proxying with F5 NGINX
Ingress Controller / NGINX Plus Ingress Controller.

Do not apply this in production. Do not use it on customer traffic without a
full routing design, security review, and rollback window.

## Goal

Test whether a UDP DNS backend can receive traffic with the original client
source IP when NGINX proxies UDP DNS through a `TransportServer`.

The UDP approach tested here is:

```nginx
proxy_bind $remote_addr transparent;
```

This is different from TCP PROXY protocol. Do not add `proxy_protocol on;` to
the UDP TransportServer.

## Current Design Assumptions

- F5 NGINX Ingress Controller / NGINX Plus Ingress Controller is already deployed.
- Controller is a DaemonSet.
- `hostNetwork` is enabled.
- DNS is exposed on port `53` for TCP and UDP.
- Backend Kubernetes Service is `coredns` in namespace `dns-lab`, port `53`.
- UDP TransportServer name is `dns-udp`.
- Ingress class is `nginx`.
- Snippets are enabled, or will be enabled with `values-transparent-lab.yaml`.

This lab does not change:

- TCP TransportServer configuration
- port `53`
- backend service `dns-lab/coredns:53`

## Files

- `dns-udp-transparent-transportserver.yaml`
  - Updates only UDP TransportServer `dns-lab/dns-udp`.
  - Adds `serverSnippets` with `proxy_bind $remote_addr transparent;`.
  - Does not add `proxy_protocol on;`.
- `values-transparent-lab.yaml`
  - Helm values overlay that enables snippets and adds controller capability
    `NET_RAW`.
- `node-transparent-routing-daemonset.yaml`
  - Lab-only privileged DaemonSet that applies reversible policy routing and
    iptables mangle rules on nodes.
- `test-commands.sh`
  - Prints current state, validates, optionally applies, and tests.
- `rollback-commands.sh`
  - Reverts the UDP TransportServer and removes node routing rules.

## Why Node Routing Is Needed

NGINX `proxy_bind ... transparent` lets upstream connections originate from a
non-local IP address, such as the real client IP. That alone is not enough.

The backend response path must also be intercepted and delivered back to NGINX.
This lab marks UDP responses from source port `53`, sends marked packets to a
custom routing table, and routes them locally through `lo` so NGINX can receive
the response path.

If DNS times out after applying this lab, assume return-path routing is wrong
and roll back.

## Helm Values Patch

Inspect and merge `values-transparent-lab.yaml` with this lab's existing values:

```bash
helm get values nginx-ingress -n nginx-ingress -o yaml
```

Apply the overlay with the existing values file:

```bash
helm upgrade nginx-ingress oci://ghcr.io/nginx/charts/nginx-ingress \
  --version 2.5.1 \
  --namespace nginx-ingress \
  -f nginx-plus-dns-values.yaml \
  -f values-transparent-lab.yaml
```

Wait for the controller:

```bash
kubectl -n nginx-ingress rollout status daemonset/nginx-ingress-controller --timeout=300s
```

If the DaemonSet name differs:

```bash
kubectl -n nginx-ingress get daemonset
```

## Required Pre-Apply Checks

Before applying anything, print current resources:

```bash
kubectl get transportserver dns-udp -n dns-lab -o yaml
helm get values nginx-ingress -n nginx-ingress -o yaml
kubectl get pods -n nginx-ingress -o wide
```

## Validate

```bash
kubectl apply --dry-run=server -f dns-udp-transparent-transportserver.yaml
```

## Apply Lab Routing

Review `node-transparent-routing-daemonset.yaml` first.

Important lab defaults:

- marks UDP packets with source port `53`
- routes marked packets through table `100`
- disables `rp_filter` and stores prior values under host `/run`
- uses a privileged `nicolaka/netshoot` DaemonSet

Apply:

```bash
kubectl apply -f node-transparent-routing-daemonset.yaml
kubectl -n kube-system rollout status daemonset/udp-transparent-routing-lab --timeout=180s
```

Verify node rules:

```bash
ROUTING_POD=$(kubectl -n kube-system get pod -l app=udp-transparent-routing-lab -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$ROUTING_POD" -- iptables -t mangle -S
kubectl -n kube-system exec "$ROUTING_POD" -- ip rule show
kubectl -n kube-system exec "$ROUTING_POD" -- ip route show table 100
```

## Apply UDP TransportServer

```bash
kubectl apply -f dns-udp-transparent-transportserver.yaml
kubectl describe transportserver dns-udp -n dns-lab
kubectl logs -n nginx-ingress -l app.kubernetes.io/name=nginx-ingress --tail=200
```

## Verify Generated NGINX Stream Config

```bash
NGINX_POD=$(kubectl -n nginx-ingress get pod -l app.kubernetes.io/name=nginx-ingress -o jsonpath='{.items[0].metadata.name}')
kubectl -n nginx-ingress exec "$NGINX_POD" -- sh -c 'nginx -T 2>/dev/null | grep -F "proxy_bind $remote_addr transparent;"'
```

Expected generated config contains:

```nginx
proxy_bind $remote_addr transparent;
```

## Test DNS

From a client inside the lab subnet:

```bash
dig @<NODE_IP> -p 53 app.example.local +short
dig @<NODE_IP> -p 53 api.example.local +short
```

From the DNS backend pod if it has `tcpdump`:

```bash
BACKEND_POD=$(kubectl -n dns-lab get pod -l app=coredns -o jsonpath='{.items[0].metadata.name}')
kubectl -n dns-lab exec -it "$BACKEND_POD" -- tcpdump -ni any udp port 53
```

If the backend image does not have `tcpdump`, capture from the lab routing
DaemonSet pod:

```bash
ROUTING_POD=$(kubectl -n kube-system get pod -l app=udp-transparent-routing-lab -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec -it "$ROUTING_POD" -- tcpdump -ni any udp port 53
```

Expected:

- UDP DNS still resolves successfully.
- Backend-side packet capture shows the original client IP as source only if
  transparent routing is correct.
- If DNS times out, assume return-path routing is wrong and roll back.

## One-Command Lab Helper

Safe dry-run only:

```bash
./test-commands.sh
```

Apply and test:

```bash
APPLY_CHANGES=true NODE_IP=<NODE_IP> ./test-commands.sh
```

## Rollback

Run:

```bash
./rollback-commands.sh
```

Rollback actions:

- reapply previous UDP TransportServer without `serverSnippets`
- remove lab node routing rules
- delete the lab routing DaemonSet and ConfigMap
- print the Helm command needed to remove `values-transparent-lab.yaml`

If snippets and `NET_RAW` were added only for this test, upgrade the controller
again without `values-transparent-lab.yaml` and wait for rollout.

## References

- NGINX stream proxy module:
  https://nginx.org/en/docs/stream/ngx_stream_proxy_module.html
- F5 NGINX Ingress Controller TransportServer resource:
  https://docs.nginx.com/nginx-ingress-controller/configuration/transportserver-resource/
- F5 NGINX Ingress Controller snippets:
  https://docs.nginx.com/nginx-ingress-controller/configuration/ingress-resources/advanced-configuration-with-snippets/
