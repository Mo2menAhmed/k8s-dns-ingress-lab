# Kubernetes DNS Ingress Lab

This lab sets up a local Kubernetes environment on WSL2 using Docker Desktop,
`kind`, F5 NGINX Ingress Controller with NGINX Plus, and `TransportServer`
resources. It exposes a DNS service through the ingress controller on local host
port `53`.

## What it does

- Creates a `kind` cluster named `dns-ingress-lab`
- Maps WSL/laptop `127.0.0.1:53` TCP/UDP to kind control-plane node container port `53`
- Installs F5 NGINX Ingress Controller with NGINX Plus using Helm
- Creates `GlobalConfiguration` listeners for TCP and UDP port `53`
- Deploys a CoreDNS demo service in namespace `dns-lab`
- Configures TCP and UDP `TransportServer` resources for port `53`
- CoreDNS answers DNS records:
  - `app.example.local` → `10.10.10.10`
  - `api.example.local` → `10.10.10.20`

## Files

- `kind-config.yaml` - kind cluster definition with port mappings
- `scripts/01-create-cluster.sh` - create the `kind` cluster
- `scripts/02-install-ingress-nginx.sh` - install F5 NGINX Ingress Controller with NGINX Plus
- `scripts/03-deploy-dns.sh` - deploy the CoreDNS demo service and TransportServers
- `scripts/04-test.sh` - test DNS queries against localhost:53
- `nginx-plus-dns-values.yaml` - Helm values for NGINX Plus ingress
- `dns-transportservers.yaml` - TCP/UDP TransportServer resources

## Prerequisites

- Docker Desktop with WSL2 integration enabled
- `kind`
- `kubectl`
- `helm`
- `dig` (from `dnsutils` or `bind-tools`)
- NGINX Plus JWT license token for the private NGINX registry

Create `license.jwt` in the repo root before running the install script, or
create the Kubernetes secrets yourself in namespace `nginx-ingress`.

The file `license.jwt` is intentionally not committed.

## Usage

Run the scripts in order from WSL2:

```bash
bash scripts/01-create-cluster.sh
bash scripts/02-install-ingress-nginx.sh
bash scripts/03-deploy-dns.sh
bash scripts/04-test.sh
```

For a customer-style runbook using the same NGINX Plus `TransportServer`
approach, see `NGINX-PLUS-TRANSPORTSERVER-GUIDE.md`.

## How it Works

1. **kind cluster** exposes WSL/laptop `127.0.0.1:53` TCP/UDP to port `53` inside the kind node container.
2. **NGINX Plus ingress controller** runs as a daemonset with `hostNetwork=true`, binding port `53` on the node.
3. **GlobalConfiguration** defines TCP and UDP listeners on port `53`.
4. **TransportServers** forward port `53` traffic to the `dns-lab/coredns` service.
5. **CoreDNS** answers DNS queries for the configured records.
6. Queries to `localhost:53` on your WSL host are forwarded by Docker into the kind node, handled by NGINX Plus on node port `53`, and forwarded to CoreDNS.

## Troubleshooting

### Cluster creation fails

- Verify Docker Desktop is running and WSL2 integration is enabled.
- Confirm `kind` and `kubectl` are available in your WSL shell.
- Run `docker info` to verify Docker is reachable from WSL.
- If you see `permission denied while trying to connect to the docker API`, make sure your WSL user can access `/var/run/docker.sock`:

```bash
sudo usermod -aG docker "$USER" && newgrp docker
```

- If `127.0.0.1:53` is already in use, stop the conflicting service or choose a different host port in `kind-config.yaml` and `scripts/04-test.sh`.
- It is normal for WSL to show listeners such as `127.0.0.53:53` or `10.255.255.254:53`; this lab binds specifically to `127.0.0.1:53`.
- If an existing cluster was created with a different port mapping, delete and recreate it:

```bash
kind delete cluster --name dns-ingress-lab
bash scripts/01-create-cluster.sh
```

### NGINX Plus ingress pod not ready

```bash
kubectl -n nginx-ingress get pods
kubectl -n nginx-ingress get events --sort-by=.lastTimestamp
kubectl -n nginx-ingress logs -l app.kubernetes.io/name=nginx-ingress
```

### DNS service not responding

- Confirm CoreDNS pod is running:

```bash
kubectl -n dns-lab get pods
kubectl -n dns-lab get svc coredns
```

- Confirm the TransportServers are valid:

```bash
kubectl -n dns-lab get transportserver
kubectl -n dns-lab describe transportserver dns-tcp
kubectl -n dns-lab describe transportserver dns-udp
```

- Use `dig` to test manually:

```bash
dig @127.0.0.1 -p 53 app.example.local
dig @127.0.0.1 -p 53 api.example.local
dig @127.0.0.1 -p 53 +tcp app.example.local
dig @127.0.0.1 -p 53 +tcp api.example.local
```

### Windows / WSL networking issues

- WSL2 forwards `localhost` to the WSL instance. If the service is not reachable from Windows, ensure Docker Desktop and WSL network forwarding are working.
- Windows firewall may block UDP/TCP traffic on port `53`. Allow the port for Docker Desktop and WSL.

## Notes

- This lab uses F5 NGINX Ingress Controller with NGINX Plus as a daemonset with `hostNetwork=true`.
- TCP/UDP traffic on port `53` is forwarded via `TransportServer` resources.
- CoreDNS runs as a standard ClusterIP-backed deployment and is reached through NGINX Plus.
- Host port `53` is mapped into the kind node, so the service is accessible at `localhost:53`.
- Port `53` may require elevated privileges on the host and must not conflict with an existing local DNS service.
