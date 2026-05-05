# Customer Guide: Install NGINX Plus Ingress for Kubernetes DNS

This guide installs only the F5 NGINX Ingress Controller with NGINX Plus.
It assumes Kubernetes is already running and the DNS service is already deployed.

The goal is to expose an existing Kubernetes DNS service on TCP and UDP port 53
using F5 NGINX `GlobalConfiguration` and `TransportServer` resources.

## Assumptions

- Kubernetes cluster is ready.
- `kubectl` is configured for the target cluster.
- Helm is installed.
- The DNS backend service already exists.
- The customer has a valid NGINX Plus JWT license token.
- The cluster nodes can pull from `private-registry.nginx.com`.

Example backend used in this guide:

```text
DNS namespace: dns-lab
DNS service:   coredns
DNS port:      53
```

If the customer DNS service has different names, replace:

```text
dns-lab/coredns:53
```

with:

```text
<dns-namespace>/<dns-service>:<dns-port>
```

## 1. Verify the Existing DNS Service

```bash
kubectl -n dns-lab get svc coredns
kubectl -n dns-lab get endpoints coredns
```

The service must expose both protocols:

```text
53/TCP
53/UDP
```

## 2. Create NGINX Plus Secrets

Save the NGINX Plus JWT locally as:

```text
license.jwt
```

Create the NGINX namespace:

```bash
kubectl create namespace nginx-ingress --dry-run=client -o yaml | kubectl apply -f -
```

Create the NGINX Plus license secret:

```bash
kubectl -n nginx-ingress create secret generic nplus-license \
  --from-file=license.jwt=./license.jwt \
  --type=nginx.com/license
```

Create the private registry pull secret:

```bash
kubectl -n nginx-ingress create secret docker-registry regcred \
  --docker-server=private-registry.nginx.com \
  --docker-username="$(cat ./license.jwt)" \
  --docker-password=none
```

Do not commit or share `license.jwt`.

## 3. Create Helm Values

Create this file:

```text
nginx-plus-dns-values.yaml
```

Use this content:

```yaml
controller:
  kind: daemonset
  nginxplus: true
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet

  image:
    repository: private-registry.nginx.com/nginx-ic/nginx-plus-ingress
    tag: 5.4.1

  serviceAccount:
    imagePullSecretName: regcred

  mgmt:
    licenseTokenSecretName: nplus-license

  enableCustomResources: true

  globalConfiguration:
    create: true
    spec:
      listeners:
      - name: dns-tcp
        port: 53
        protocol: TCP
      - name: dns-udp
        port: 53
        protocol: UDP

  customPorts:
  - name: dns-tcp
    containerPort: 53
    protocol: TCP
  - name: dns-udp
    containerPort: 53
    protocol: UDP

  service:
    create: false
```

Notes:

- `hostNetwork: true` binds NGINX directly on the Kubernetes node network.
- Port `53` must be free on the nodes where this DaemonSet runs.
- If another DNS service is already listening on node port `53`, this deployment will fail.

## 4. Install NGINX Plus Ingress Controller

```bash
helm upgrade --install nginx-ingress oci://ghcr.io/nginx/charts/nginx-ingress \
  --version 2.5.1 \
  --namespace nginx-ingress \
  -f nginx-plus-dns-values.yaml
```

Wait for the controller:

```bash
kubectl -n nginx-ingress wait \
  --for=condition=Ready pod \
  -l app.kubernetes.io/name=nginx-ingress \
  --timeout=600s
```

Verify:

```bash
kubectl -n nginx-ingress get pods
kubectl -n nginx-ingress get globalconfiguration
helm -n nginx-ingress list
```

## 5. Create TransportServer Resources

Create this file:

```text
dns-transportservers.yaml
```

Use this content:

```yaml
apiVersion: k8s.nginx.org/v1
kind: TransportServer
metadata:
  name: dns-tcp
  namespace: dns-lab
spec:
  listener:
    name: dns-tcp
    protocol: TCP
  upstreams:
  - name: dns
    service: coredns
    port: 53
  action:
    pass: dns
---
apiVersion: k8s.nginx.org/v1
kind: TransportServer
metadata:
  name: dns-udp
  namespace: dns-lab
spec:
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
```

Apply it:

```bash
kubectl apply -f dns-transportservers.yaml
```

## 6. Verify TransportServer Status

```bash
kubectl -n dns-lab get transportserver
kubectl -n dns-lab describe transportserver dns-tcp
kubectl -n dns-lab describe transportserver dns-udp
```

Expected status:

```text
NAME      STATE   REASON
dns-tcp   Valid   AddedOrUpdated
dns-udp   Valid   AddedOrUpdated
```

## 7. Test DNS

Set the node IP where NGINX Plus is running:

```bash
NODE_IP=<nginx-ingress-node-ip>
```

Test UDP:

```bash
dig @"$NODE_IP" -p 53 app.example.local +short
dig @"$NODE_IP" -p 53 api.example.local +short
```

Test TCP:

```bash
dig @"$NODE_IP" -p 53 app.example.local +tcp +short
dig @"$NODE_IP" -p 53 api.example.local +tcp +short
```

Expected demo answers:

```text
app.example.local -> 10.10.10.10
api.example.local -> 10.10.10.20
```

## 8. Troubleshooting

Check image pull and license issues:

```bash
kubectl -n nginx-ingress get events --sort-by=.lastTimestamp
kubectl -n nginx-ingress describe pod -l app.kubernetes.io/name=nginx-ingress
kubectl -n nginx-ingress get secret nplus-license regcred
```

Check NGINX Plus logs:

```bash
kubectl -n nginx-ingress logs -l app.kubernetes.io/name=nginx-ingress --tail=100
```

Check listener configuration:

```bash
kubectl -n nginx-ingress get globalconfiguration nginx-ingress-controller -o yaml
```

Check TransportServer configuration:

```bash
kubectl -n dns-lab get transportserver -o yaml
```

Check the DNS backend:

```bash
kubectl -n dns-lab get pods
kubectl -n dns-lab get svc coredns
kubectl -n dns-lab get endpoints coredns
```

Common issues:

- Port `53` is already used on the node.
- The NGINX Plus JWT is expired or invalid.
- The cluster cannot reach `private-registry.nginx.com`.
- The DNS service name or namespace in the TransportServer is wrong.
- The DNS service does not expose both TCP and UDP port `53`.

## References

- F5 NGINX Ingress Controller Helm install:
  https://docs.nginx.com/nginx-ingress-controller/install/helm/
- F5 NGINX TransportServer resources:
  https://docs.nginx.com/nginx-ingress-controller/configuration/transportserver-resource/
- F5 NGINX GlobalConfiguration resource:
  https://docs.nginx.com/nginx-ingress-controller/configuration/global-configuration/globalconfiguration-resource/
