# NGINX Plus TransportServer DNS Guide

This guide installs F5 NGINX Ingress Controller with NGINX Plus and exposes an
existing Kubernetes DNS service through `TransportServer` resources.

## Assumptions

- The DNS service already exists in Kubernetes.
- Example backend:
  - Namespace: `dns-lab`
  - Service: `coredns`
  - Port: `53`
- The customer has a valid NGINX Plus JWT license token.
- The customer can pull from `private-registry.nginx.com`.

## Create Secrets

Save the JWT locally as `license.jwt`, then create the namespace and secrets:

```bash
kubectl create namespace nginx-ingress --dry-run=client -o yaml | kubectl apply -f -

kubectl -n nginx-ingress create secret generic nplus-license \
  --from-file=license.jwt=./license.jwt \
  --type=nginx.com/license

kubectl -n nginx-ingress create secret docker-registry regcred \
  --docker-server=private-registry.nginx.com \
  --docker-username="$(cat ./license.jwt)" \
  --docker-password=none
```

Do not commit `license.jwt`.

## Install NGINX Plus Ingress Controller

Use the values file from this repo:

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

## Apply TransportServers

```bash
kubectl apply -f dns-transportservers.yaml
```

## Verify

```bash
kubectl -n nginx-ingress get pods
kubectl -n nginx-ingress get globalconfiguration
kubectl -n dns-lab get transportserver
kubectl -n dns-lab describe transportserver dns-tcp
kubectl -n dns-lab describe transportserver dns-udp
```

Both TransportServers should show:

```text
STATE   REASON
Valid   AddedOrUpdated
```

## Test

For a host-network install, query the node IP:

```bash
NODE_IP=<node-ip>

dig @"$NODE_IP" -p 53 app.example.local +short
dig @"$NODE_IP" -p 53 api.example.local +short
dig @"$NODE_IP" -p 53 app.example.local +tcp +short
dig @"$NODE_IP" -p 53 api.example.local +tcp +short
```

For a local kind lab that maps port `53` to `127.0.0.1`:

```bash
dig @127.0.0.1 -p 53 app.example.local +short
dig @127.0.0.1 -p 53 api.example.local +short
dig @127.0.0.1 -p 53 app.example.local +tcp +short
dig @127.0.0.1 -p 53 api.example.local +tcp +short
```

## Troubleshooting

Check image pull and licensing:

```bash
kubectl -n nginx-ingress get events --sort-by=.lastTimestamp
kubectl -n nginx-ingress describe pod -l app.kubernetes.io/name=nginx-ingress
kubectl -n nginx-ingress get secret nplus-license regcred
```

Check listener and TransportServer status:

```bash
kubectl -n nginx-ingress get globalconfiguration nginx-ingress-controller -o yaml
kubectl -n dns-lab get transportserver -o yaml
kubectl -n nginx-ingress logs -l app.kubernetes.io/name=nginx-ingress --tail=100
```
