# OpenChoreo Deployment Guide

> **Stack:** OpenChoreo v0.16+ API platform
> **K8s requirement:** Kubernetes 1.32+
> **Helm chart source:** `oci://ghcr.io/openchoreo/helm-charts/`

OpenChoreo is a cloud-native internal developer platform built on Kubernetes. It provides API
management, developer self-service, and an integrated build pipeline. This guide deploys it
across four VLANs for maximum isolation:

- **PUBLIC VLAN** — Nginx LB proxy VM (exposes choreo, choreo-api, choreo-id to the internet)
- **PRIVATE VLAN** — RKE2 K8s cluster (all OpenChoreo components run here)
- **DATA VLAN** — PostgreSQL Primary-Standby (Backstage portal DB + Thunder IdP DB)
- **SYSTEM VLAN** — Redis/KV store (optional; OpenChoreo v0.16 does not require Redis)

---

## 1. Architecture

```
Internet
   │  HTTPS :443
   ▼
┌─────────────────────────────┐  PUBLIC VLAN (10.N.0.0/24)
│  Nginx proxy VM             │
│  IP: 10.N.0.10 (static)     │
│  DNS: choreo.sre-N.internal │
│       choreo-api.sre-N.int  │
│       choreo-id.sre-N.int   │
└────────┬────────────────────┘
         │  NodePort :30080 / :30443
         ▼  (VyOS PUB-TO-PRIV rule)
┌─────────────────────────────────────────┐  PRIVATE VLAN (10.N.1.0/24)
│  RKE2 K8s Cluster (managed by Rancher)  │
│                                         │
│  ┌──────────┐  ┌──────────┐             │
│  │ kgateway │  │ Thunder  │ ← IdP       │
│  │ (Envoy)  │  │ (OAuth2) │             │
│  └──────────┘  └──────────┘             │
│  ┌──────────┐  ┌──────────┐             │
│  │Backstage │  │ Choreo   │ ← control   │
│  │ portal   │  │ API +    │   plane     │
│  └──────────┘  │ Ctrl Mgr │             │
│                └──────────┘             │
│  ┌─────────────────────────┐            │
│  │ Data plane + Cluster GW │            │
│  │ (WebSocket :8443)       │            │
│  └─────────────────────────┘            │
└──────────┬──────────────────────────────┘
           │
    ┌──────┴──────┐
    │             │
    ▼             ▼
DATA VLAN       SYSTEM VLAN
10.N.3.10       10.N.2.10
PostgreSQL      Redis (optional)
primary
10.N.3.11
standby
```

---

## 2. IP and DNS Allocation

### Reserved IPs for this deployment

| Component | Zone | Static IP | Purpose |
|-----------|------|-----------|---------|
| Nginx LB proxy | PUBLIC | `10.N.0.10` | Single ingress entry point |
| PostgreSQL primary | DATA | `10.N.3.10` | Backstage + Thunder databases |
| PostgreSQL standby | DATA | `10.N.3.11` | Read-only / failover |

Replace `N` with your team offset (sre-alpha = 1, so IPs become 10.1.0.10, 10.1.3.10, etc.).

### DNS names to register

Add these to `extra_service_dns` in your `terraform.tfvars`:

```hcl
extra_service_dns = {
  # OpenChoreo — all routes go through the Nginx LB proxy in PUBLIC VLAN
  "choreo"     = "10.N.0.10"   # Developer portal (Backstage)
  "choreo-api" = "10.N.0.10"   # OpenChoreo API server
  "choreo-id"  = "10.N.0.10"   # Thunder OAuth2/OIDC identity provider
}
```

Full FQDNs will be:
- `choreo.sre-<team>.internal` → Backstage developer portal
- `choreo-api.sre-<team>.internal` → OpenChoreo API + controller
- `choreo-id.sre-<team>.internal` → Thunder IdP (OAuth2 token endpoint)

After editing `terraform.tfvars`, run `terraform apply` to push the DNS entries into VyOS.

---

## 3. Prerequisites Checklist

Before starting:

```
[ ] Platform infra/ has been applied (namespace + RBAC exist)
[ ] VyOS router is running (terraform apply in team VPC)
[ ] RKE2 cluster is Active in Rancher (rke2_cluster.tf applied)
[ ] PostgreSQL primary+standby are running (postgresql_ha.tf applied)
[ ] extra_service_dns updated in terraform.tfvars and applied
[ ] kubectl context is set to the RKE2 cluster
[ ] helm v3.14+ installed locally
[ ] openssl / cfssl available for TLS certs
```

Verify kubectl context:

```bash
kubectl config current-context
kubectl get nodes    # all nodes Ready
kubectl version --short
# Server Version must be >= v1.32
```

---

## 4. PostgreSQL Database Setup

SSH to the PostgreSQL primary VM and create the two databases OpenChoreo needs:

```bash
ssh ubuntu@10.N.3.10

sudo -u postgres psql <<'SQL'
-- ── Thunder IdP database ──
CREATE DATABASE thunder;
CREATE USER thunder WITH PASSWORD 'CHANGE_THIS_thunder_password';
GRANT ALL PRIVILEGES ON DATABASE thunder TO thunder;
\c thunder
GRANT ALL ON SCHEMA public TO thunder;

-- ── Backstage developer portal database ──
CREATE DATABASE backstage;
CREATE USER backstage WITH PASSWORD 'CHANGE_THIS_backstage_password';
GRANT ALL PRIVILEGES ON DATABASE backstage TO backstage;
\c backstage
GRANT ALL ON SCHEMA public TO backstage;

\l   -- verify both databases appear
SQL
```

> **Note:** Change the passwords above. Store them in a Kubernetes Secret or Vault before
> deploying the Helm charts — you'll reference them in the Helm values files.

Create a Kubernetes secret for the database credentials:

```bash
kubectl create namespace choreo-system

kubectl create secret generic choreo-db-credentials \
  --namespace choreo-system \
  --from-literal=thunder-db-url="postgresql://thunder:CHANGE_THIS_thunder_password@postgres.default.svc.cluster.local:5432/thunder" \
  --from-literal=backstage-db-url="postgresql://backstage:CHANGE_THIS_backstage_password@postgres.default.svc.cluster.local:5432/backstage"
```

> The service name `postgres.default.svc.cluster.local` comes from `service_dns.tf.example`.
> If you haven't applied it yet, do so now (copy → `service_dns.tf` → `terraform apply`).
> This creates a K8s Service + Endpoints object pointing to `10.N.3.10`.

---

## 5. Nginx LB Proxy VM (PUBLIC VLAN)

This VM lives in the PUBLIC VLAN and acts as the internet-facing entry point. It proxies HTTPS
requests to the NodePort services exposed by the kgateway running on the RKE2 cluster in the
PRIVATE VLAN.

### 5.1 Create the proxy VM

Create `nginx_lb.tf` in your team VPC directory:

```hcl
# nginx_lb.tf — Nginx reverse proxy in PUBLIC VLAN
# Forwards internet traffic to OpenChoreo kgateway NodePort services.

locals {
  nginx_ip = cidrhost(var.vlans.public.cidr, 10)   # 10.N.0.10
}

# Static IP network_data for cloud-init
resource "harvester_cloudinit_secret" "nginx_lb_config" {
  name      = "nginx-lb-cloudinit"
  namespace = var.namespace

  user_data = <<-USERDATA
    #cloud-config
    hostname: nginx-lb
    fqdn: nginx-lb.${var.dns_domain}
    manage_etc_hosts: true

    packages:
      - nginx

    write_files:
      - path: /etc/nginx/sites-available/choreo
        content: |
          # OpenChoreo — route by Host header to correct upstream NodePort
          # Replace RKE2_NODE_IP with the IP of any RKE2 worker node (10.N.1.x).
          # Replace :30443 with the actual NodePort assigned by kgateway.
          upstream choreo_backend {
            server RKE2_NODE_IP:30443;   # kgateway HTTPS NodePort
          }

          server {
            listen 443 ssl;
            server_name choreo.${var.dns_domain}
                        choreo-api.${var.dns_domain}
                        choreo-id.${var.dns_domain};

            ssl_certificate     /etc/ssl/choreo/tls.crt;
            ssl_certificate_key /etc/ssl/choreo/tls.key;

            location / {
              proxy_pass         https://choreo_backend;
              proxy_ssl_verify   off;    # kgateway uses internal CA
              proxy_set_header   Host $host;
              proxy_set_header   X-Real-IP $remote_addr;
              proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header   X-Forwarded-Proto $scheme;
            }
          }

          server {
            listen 80;
            server_name choreo.${var.dns_domain}
                        choreo-api.${var.dns_domain}
                        choreo-id.${var.dns_domain};
            return 301 https://$host$request_uri;
          }

    runcmd:
      - ln -sf /etc/nginx/sites-available/choreo /etc/nginx/sites-enabled/choreo
      - rm -f /etc/nginx/sites-enabled/default
      - mkdir -p /etc/ssl/choreo
      # Place your certs at /etc/ssl/choreo/tls.crt and tls.key
      # then: systemctl restart nginx
  USERDATA

  network_data = <<-NETDATA
    version: 2
    ethernets:
      enp1s0:
        addresses:
          - ${local.nginx_ip}/${split("/", var.vlans.public.cidr)[1]}
        gateway4: ${var.vlans.public.gateway}
        nameservers:
          addresses:
            - ${var.vlans.public.gateway}
          search:
            - ${var.dns_domain}
  NETDATA
}

resource "harvester_virtualmachine" "nginx_lb" {
  name      = "nginx-lb"
  namespace = var.namespace

  cpu    = 1
  memory = "1Gi"

  network_interface {
    name         = "nic-public"
    model        = "virtio"
    type         = "bridge"
    network_name = harvester_network.vpc_vlans["public"].id
  }

  disk {
    name       = "root"
    type       = "disk"
    size       = "10Gi"
    bus        = "virtio"
    boot_order = 1
    image      = harvester_image.ubuntu.id
  }

  cloudinit {
    user_data_secret_name    = harvester_cloudinit_secret.nginx_lb_config.name
    network_data_secret_name = harvester_cloudinit_secret.nginx_lb_config.name
  }

  depends_on = [harvester_network.vpc_vlans]
}

output "nginx_lb_ip" {
  value       = local.nginx_ip
  description = "Nginx LB proxy IP in PUBLIC VLAN"
}
```

Apply:

```bash
terraform apply -target=harvester_cloudinit_secret.nginx_lb_config \
                -target=harvester_virtualmachine.nginx_lb
```

### 5.2 Discover kgateway NodePorts

After OpenChoreo is installed (Step 8), retrieve the NodePort values and update the Nginx config:

```bash
kubectl get svc -n choreo-system -l app.kubernetes.io/name=kgateway
# Note the NodePort assigned to port 443 (e.g. 30443)

# Get the IP of any RKE2 worker node
kubectl get nodes -o wide | grep worker
```

SSH to the proxy VM and update `/etc/nginx/sites-available/choreo`:

```bash
ssh ubuntu@10.N.0.10
sudo sed -i 's/RKE2_NODE_IP/10.N.1.101/g' /etc/nginx/sites-available/choreo
sudo sed -i 's/30443/ACTUAL_NODEPORT/g'   /etc/nginx/sites-available/choreo
sudo nginx -t && sudo systemctl restart nginx
```

---

## 6. TLS Certificates

OpenChoreo's components communicate over TLS internally. You need:

1. **Wildcard cert** for `*.sre-<team>.internal` — for Nginx and Thunder
2. **cert-manager** inside K8s — for inter-service TLS (kgateway ↔ backend)

### Option A: Self-signed wildcard (dev/lab)

```bash
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=*.sre-<team>.internal" \
  -addext "subjectAltName=DNS:*.sre-<team>.internal,DNS:sre-<team>.internal"

# Copy to Nginx proxy VM
scp tls.crt tls.key ubuntu@10.N.0.10:/tmp/
ssh ubuntu@10.N.0.10 "sudo mv /tmp/tls.* /etc/ssl/choreo/ && sudo systemctl restart nginx"

# Create K8s secret for Thunder and Backstage
kubectl create secret tls choreo-tls \
  --namespace choreo-system \
  --cert=tls.crt \
  --key=tls.key
```

### Option B: cert-manager with Let's Encrypt (production)

Install cert-manager:

```bash
helm upgrade --install cert-manager \
  oci://ghcr.io/cert-manager/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

Create a ClusterIssuer pointing to Let's Encrypt (requires public DNS + port 80 reachable).

---

## 7. Kubernetes Prerequisites

Install these before the OpenChoreo Helm charts. Order matters.

### 7.1 Gateway API CRDs

kgateway requires the standard Gateway API CRDs:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/experimental-install.yaml
```

### 7.2 cert-manager

```bash
helm upgrade --install cert-manager \
  oci://ghcr.io/cert-manager/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait
```

### 7.3 external-secrets (optional but recommended)

```bash
helm upgrade --install external-secrets \
  oci://ghcr.io/external-secrets/charts/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait
```

### 7.4 Verify

```bash
kubectl get pods -n cert-manager
# All pods should be Running

kubectl get crd | grep gateway.networking.k8s.io
# Should list: gateways, httproutes, grpcroutes, etc.
```

---

## 8. Install Thunder (OAuth2/OIDC Identity Provider)

Thunder is OpenChoreo's built-in IdP. It must be installed before the control plane because
the control plane references Thunder's token endpoint.

Create `thunder-values.yaml`:

```yaml
# thunder-values.yaml
database:
  # Uses K8s service name from service_dns.tf.example
  url: "postgresql://thunder:CHANGE_THIS@postgres.default.svc.cluster.local:5432/thunder"

ingress:
  enabled: false   # We use Nginx proxy + kgateway instead

service:
  type: ClusterIP

config:
  # Public-facing URL — how end users reach the IdP
  issuerUrl: "https://choreo-id.sre-<team>.internal"

tls:
  secretName: choreo-tls   # created in Step 6
```

Install:

```bash
helm upgrade --install thunder \
  oci://ghcr.io/openchoreo/helm-charts/thunder \
  --namespace choreo-system \
  --create-namespace \
  -f thunder-values.yaml \
  --wait
```

Verify:

```bash
kubectl get pods -n choreo-system -l app.kubernetes.io/name=thunder
# STATUS: Running

# Check Thunder is responding (from inside the cluster)
kubectl run curl-test --image=curlimages/curl --restart=Never -it --rm -- \
  curl -s https://thunder.choreo-system.svc.cluster.local:8443/.well-known/openid-configuration
# Should return JSON with issuer, jwks_uri, etc.
```

---

## 9. Install OpenChoreo Control Plane

Create `openchoreo-cp-values.yaml`:

```yaml
# openchoreo-cp-values.yaml

global:
  # Public-facing URLs — must match the DNS names in extra_service_dns
  portalUrl:   "https://choreo.sre-<team>.internal"
  apiUrl:      "https://choreo-api.sre-<team>.internal"
  identityUrl: "https://choreo-id.sre-<team>.internal"

backstage:
  database:
    url: "postgresql://backstage:CHANGE_THIS@postgres.default.svc.cluster.local:5432/backstage"

thunder:
  # Point control plane at Thunder's cluster-internal endpoint
  url: "https://thunder.choreo-system.svc.cluster.local:8443"
  # Client credentials — obtain from Thunder admin setup
  clientId:     "choreo-control-plane"
  clientSecret: "CHANGE_THIS_oidc_secret"

kgateway:
  # kgateway creates a LoadBalancer service; on bare-metal it will stay Pending.
  # We use NodePort instead and front it with the Nginx proxy.
  service:
    type: NodePort
    httpsNodePort: 30443
    httpNodePort:  30080

tls:
  secretName: choreo-tls
```

Install:

```bash
helm upgrade --install openchoreo \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo \
  --namespace choreo-system \
  -f openchoreo-cp-values.yaml \
  --wait --timeout 10m
```

Monitor rollout:

```bash
kubectl get pods -n choreo-system -w
# Wait for all pods to reach Running/Completed
# Key pods: choreo-api, choreo-controller-manager, backstage, kgateway
```

---

## 10. Install OpenChoreo Data Plane

The data plane handles runtime API traffic. It runs alongside the control plane in the PRIVATE VLAN.

Create `openchoreo-dp-values.yaml`:

```yaml
# openchoreo-dp-values.yaml
controlPlane:
  url: "https://choreo-api.sre-<team>.internal"
  # Or use cluster-internal endpoint:
  # url: "https://choreo-api.choreo-system.svc.cluster.local"

clusterGateway:
  # WebSocket port 8443 for cluster gateway
  port: 8443
```

Install:

```bash
helm upgrade --install openchoreo-data-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
  --namespace choreo-system \
  -f openchoreo-dp-values.yaml \
  --wait --timeout 5m
```

---

## 11. Update Nginx NodePorts

Now that OpenChoreo is installed, get the actual NodePorts and update the Nginx proxy:

```bash
# Get kgateway NodePorts
kubectl get svc -n choreo-system | grep kgateway
# Example output:
#   kgateway   NodePort   10.x.x.x   <none>   80:30080/TCP,443:30443/TCP

# Get an RKE2 worker node IP
kubectl get nodes -o wide
# Example: 10.N.1.101

# Update Nginx config on the proxy VM
ssh ubuntu@10.N.0.10
sudo nano /etc/nginx/sites-available/choreo
# Replace RKE2_NODE_IP → 10.N.1.101
# Replace 30443 → actual HTTPS NodePort
sudo nginx -t && sudo systemctl restart nginx
```

---

## 12. Verification

### 12.1 DNS resolution

From any VLAN VM or the VyOS router:

```bash
dig @10.N.1.1 choreo.sre-<team>.internal     # → 10.N.0.10
dig @10.N.1.1 choreo-api.sre-<team>.internal  # → 10.N.0.10
dig @10.N.1.1 choreo-id.sre-<team>.internal   # → 10.N.0.10
dig @10.N.1.1 postgres.sre-<team>.internal    # → 10.N.3.10
```

### 12.2 OpenChoreo API

```bash
# Health check (from inside the K8s cluster or a PRIVATE VLAN VM)
curl -k https://choreo-api.sre-<team>.internal/healthz
# Expected: {"status":"ok"}

# From outside (via Nginx proxy on PUBLIC VLAN)
curl -k https://choreo.sre-<team>.internal
# Expected: Backstage portal HTML or redirect
```

### 12.3 Thunder IdP

```bash
curl -k https://choreo-id.sre-<team>.internal/.well-known/openid-configuration | jq .issuer
# Expected: "https://choreo-id.sre-<team>.internal"
```

### 12.4 K8s pod→database connectivity

```bash
kubectl run pg-test --namespace choreo-system --image=postgres:16 \
  --restart=Never -it --rm -- \
  psql "postgresql://backstage:CHANGE_THIS@postgres.default.svc.cluster.local:5432/backstage" \
  -c "SELECT 1;"
# Expected: (1 row)
```

### 12.5 All pods healthy

```bash
kubectl get pods -n choreo-system
# All should be Running or Completed (init containers)

kubectl get gateway -n choreo-system
# kgateway Gateway should show PROGRAMMED=True
```

---

## 13. Full terraform.tfvars Additions

Summary of all `terraform.tfvars` additions needed for this deployment:

```hcl
# ── Internal DNS for OpenChoreo ──
dns_domain = "sre-<team>.internal"

extra_service_dns = {
  # LB proxy in PUBLIC VLAN — fronts all three OpenChoreo endpoints
  "choreo"     = "10.N.0.10"
  "choreo-api" = "10.N.0.10"
  "choreo-id"  = "10.N.0.10"
}

# ── PostgreSQL static IPs are already in cloudinit.tf defaults ──
# postgres.sre-<team>.internal    → 10.N.3.10  (auto-registered)
# postgres-ro.sre-<team>.internal → 10.N.3.11  (auto-registered)
```

After editing, apply:

```bash
terraform apply   # pushes DNS entries into VyOS static-host-mapping
```

---

## 14. Firewall Notes

The VyOS firewall rules already support this deployment out of the box:

| Traffic | Rule | Status |
|---------|------|--------|
| Internet → Nginx proxy (443) | `WAN-TO-PUBLIC` rule 20 | ✅ Already open |
| Nginx → K8s NodePort (30443) | `PUB-TO-PRIV` rule 20 (NodePort range) | ✅ Already open |
| K8s → PostgreSQL (5432) | `PRIV-TO-DATA` rule 20 | ✅ Already open |
| K8s → Redis (6379) | `PRIV-TO-SYS` rule 40 | ✅ Already open (if using Redis) |
| Internet → K8s API (6443) | `WAN-TO-PRIV` rule 20 | ✅ Restricted to Rancher CIDR |

**No manual VyOS changes needed** for a standard OpenChoreo deployment.

> If you need to expose additional ports (e.g., the Cluster Gateway WebSocket port 8443),
> add a new rule to the appropriate VyOS ruleset. Port 8443 can be added to `WAN-TO-PUBLIC`
> if the Cluster Gateway needs to be externally reachable.

---

## 15. Optional: Redis for OpenChoreo

OpenChoreo v0.16+ does **not require** Redis — kgateway handles rate limiting natively.
However, if your team already has a Redis instance running (from `kv_store.tf`) and wants to
use it for other workloads, it remains available at:

- VM FQDN: `redis.sre-<team>.internal:6379`
- K8s FQDN: `redis.default.svc.cluster.local:6379`

---

## 16. Optional: Build Plane

The build plane enables CI/CD pipelines within OpenChoreo. It requires additional compute in
the PRIVATE VLAN and a container registry.

```bash
helm upgrade --install openchoreo-build-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-build-plane \
  --namespace choreo-system \
  -f openchoreo-bp-values.yaml \
  --wait --timeout 10m
```

Refer to the [OpenChoreo official docs](https://openchoreo.io/docs) for `openchoreo-bp-values.yaml`
configuration, especially the registry credentials and build runner sizing.

---

## 17. Optional: Observability Plane

The observability plane adds Prometheus, Grafana, and OpenTelemetry collection.

```bash
helm upgrade --install openchoreo-observability \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability \
  --namespace choreo-system \
  --wait --timeout 15m
```

Access Grafana via a NodePort or by adding a DNS entry:

```hcl
extra_service_dns = {
  # ... existing entries ...
  "choreo-obs" = "10.N.0.10"   # Route via Nginx proxy
}
```

---

## 18. Troubleshooting

### Pods stuck in Init or CrashLoopBackOff

```bash
kubectl describe pod <pod-name> -n choreo-system
kubectl logs <pod-name> -n choreo-system --previous
```

Common causes:
- Database URL wrong or unreachable → test with `kubectl run pg-test` (see Step 12.4)
- Thunder not ready before control plane started → `helm upgrade` control plane after Thunder is Running
- TLS secret missing → check `kubectl get secret choreo-tls -n choreo-system`

### Nginx returns 502 Bad Gateway

kgateway NodePort may have changed after a pod restart:

```bash
kubectl get svc kgateway -n choreo-system -o jsonpath='{.spec.ports}'
# Update Nginx config with the new NodePort
```

### DNS not resolving choreo.sre-<team>.internal

1. Confirm `terraform apply` ran after adding to `extra_service_dns`
2. SSH to VyOS and verify: `show system static-host-mapping`
3. Test from VyOS: `nslookup choreo.sre-<team>.internal 127.0.0.1`

### K8s pods can't reach PostgreSQL

1. Confirm `service_dns.tf` was applied: `kubectl get svc postgres -n default`
2. Test connectivity: `kubectl run pg-test ...` (see Step 12.4)
3. Check VyOS PRIV-TO-DATA firewall: `show firewall ipv4 name PRIV-TO-DATA`

### Thunder OIDC discovery fails

```bash
# Check Thunder is running
kubectl get pods -n choreo-system -l app.kubernetes.io/name=thunder

# Check Thunder's own logs
kubectl logs -n choreo-system deploy/thunder

# Verify database connectivity from Thunder pod
kubectl exec -n choreo-system deploy/thunder -- \
  psql "$THUNDER_DATABASE_URL" -c "SELECT 1;"
```
