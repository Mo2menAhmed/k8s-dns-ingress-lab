# UDP Transparent Proxying for DNS TransportServer

This repo is a local Kubernetes lab for UDP transparent proxying with F5 NGINX
Ingress Controller / NGINX Plus Ingress Controller.

The active manifests use a production-shaped hardening profile for this lab:
minimal Linux capabilities on the controller, no privilege escalation, a pinned
routing image digest, and backend-source routing narrowed to the current kind
Pod CIDR. For real customer production, adapt the CIDRs, image policy, node
lifecycle, and rollback process to the target environment before applying.

Important: with the stock NGINX Plus Ingress image used here, strict non-root
container execution was tested and does not work for UDP transparent proxying.
The controller and NGINX master process must run as root so NGINX can make
`CAP_NET_RAW` effective for `IP_TRANSPARENT`. NGINX worker processes still drop
to UID `101`.

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
  - Helm values overlay that enables snippets.
  - Runs the controller and NGINX master as root because this image needs
    effective capabilities for `IP_TRANSPARENT`.
  - Drops all default capabilities and adds only `CHOWN`, `SETUID`, `SETGID`,
    `NET_BIND_SERVICE`, and `NET_RAW`.
  - Sets `allowPrivilegeEscalation: false`.
- `node-transparent-routing-daemonset.yaml`
  - Privileged DaemonSet that applies reversible policy routing and iptables
    mangle rules on nodes.
  - Pins the routing container by digest.
  - Restricts backend response marking to the kind Pod CIDR `10.244.0.0/24`.
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

This overlay intentionally runs the controller master process as root, but with
all default capabilities dropped. In this kind/WSL lab, adding `NET_RAW` while
the image ran as UID `101` left the capability unavailable to NGINX at runtime,
and UDP queries failed with:

```text
setsockopt(IP_TRANSPARENT) failed (1: Operation not permitted)
```

The applied controller capability set is intentionally small:

```yaml
controller:
  securityContext:
    runAsUser: 0
    runAsNonRoot: false
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL
      add:
      - CHOWN
      - SETGID
      - SETUID
      - NET_BIND_SERVICE
      - NET_RAW
```

Strict non-root was tested with `runAsUser: 101`, `runAsNonRoot: true`,
`NET_BIND_SERVICE`, and `NET_RAW`. The pod started, but Linux exposed only
`NET_BIND_SERVICE` as effective capability:

```text
CapEff: 0000000000000400
CapBnd: 0000000000002400
```

UDP transparent proxying then failed with:

```text
setsockopt(IP_TRANSPARENT) failed (1: Operation not permitted)
```

For a strict non-root production requirement, use a vendor-supported image or
custom image/runtime design that can make `CAP_NET_RAW` effective for the NGINX
process without running the controller master as root. The standard Kubernetes
container `capabilities.add` field was not enough with this image in this lab.

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

## Apply Node Routing

Review `node-transparent-routing-daemonset.yaml` first.

Important defaults in this lab:

- marks UDP packets with source port `53` only from `10.244.0.0/24`
- routes marked packets through table `100`
- disables `rp_filter` and stores prior values under host `/run`
- uses a privileged node DaemonSet because it changes host network rules
- pins `docker.io/nicolaka/netshoot` by digest

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

Expected mangle rule:

```text
-A PREROUTING -s 10.244.0.0/24 -p udp --sport 53 -m comment --comment udp-transparent-dns-lab -j MARK --set-xmark 0x56/0xffffffff
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
kubectl -n nginx-ingress exec "$NGINX_POD" -- sh -c "nginx -T 2>/dev/null | grep -F 'proxy_bind \$remote_addr transparent;'"
```

Expected generated config contains:

```nginx
proxy_bind $remote_addr transparent;
```

Verify the hardened controller capability profile:

```bash
NGINX_POD=$(kubectl -n nginx-ingress get pod -l app.kubernetes.io/name=nginx-ingress -o jsonpath='{.items[0].metadata.name}')
kubectl -n nginx-ingress exec "$NGINX_POD" -- sh -c 'id; grep -E "Cap(Prm|Eff|Bnd)|NoNewPrivs|Seccomp" /proc/1/status'
```

Expected in this lab:

```text
uid=0(root)
CapEff: 00000000000024c1
NoNewPrivs: 1
Seccomp: 2
```

Verify that NGINX workers are non-root and hold only `CAP_NET_RAW`:

```bash
NGINX_POD=$(kubectl -n nginx-ingress get pod -l app.kubernetes.io/name=nginx-ingress -o jsonpath='{.items[0].metadata.name}')
kubectl -n nginx-ingress exec "$NGINX_POD" -- sh -c '
for d in /proc/[0-9]*; do
  cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null || true)
  case "$cmd" in
    "nginx: worker"*) echo "$d"; grep -E "Uid|Gid|CapEff" "$d/status"; break ;;
  esac
done'
```

Expected worker profile:

```text
Uid: 101 101 101 101
Gid: 101 101 101 101
CapEff: 0000000000002000
```

## Test DNS

From a client inside the lab subnet:

```bash
dig @<NODE_IP> -p 53 app.example.local +short
dig @<NODE_IP> -p 53 api.example.local +short
```

Get the node IP and the kind host port mappings:

```bash
kubectl get node dns-ingress-lab-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}'
docker port dns-ingress-lab-control-plane 53/udp
docker port dns-ingress-lab-control-plane 53/tcp
```

From WSL on the same laptop, the kind mapping normally exposes DNS on
`127.0.0.1:53`:

```bash
dig @127.0.0.1 -p 53 app.example.local +short +time=2 +tries=1
dig @127.0.0.1 -p 53 api.example.local +short +time=2 +tries=1
```

In this kind/WSL path, the client IP seen inside the kind node is normally the
Docker bridge peer, for example `172.19.0.1`.

Test from an in-cluster client against the node IP:

```bash
NODE_IP=$(kubectl get node dns-ingress-lab-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
kubectl run dns-client-nodeip --rm -it --restart=Never --image=nicolaka/netshoot -- \
  dig @"$NODE_IP" -p 53 app.example.local +short +time=2 +tries=1
```

Check what CoreDNS received:

```bash
kubectl -n dns-lab logs -l app=coredns --tail=20
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
