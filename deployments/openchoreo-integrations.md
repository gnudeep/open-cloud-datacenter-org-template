# OpenChoreo — Service Integration Reference

This document explains how every service in the OpenChoreo deployment connects to every other
service, and how traffic moves across the four VLAN zones. Read this alongside the
[deployment guide](./openchoreo.md) and the
[Terraform workspace](./openchoreo/).

---

## Component Map

```
┌──────────────────────────────────────────────────────────────────────┐
│  MANAGEMENT NETWORK  192.168.1.0/24                                  │
│  VyOS mgmt IP: 192.168.1.N*10    Rancher server: 192.168.1.x        │
└──────────────┬───────────────────────────────────────────────────────┘
               │ eth0 (WAN)
        ┌──────▼──────────────────────────────────────────────────────┐
        │                     VyOS Router VM                          │
        │  eth0 WAN    eth1 PUBLIC   eth2 PRIVATE  eth3 SYSTEM  eth4 DATA │
        └──┬──────────────┬──────────────┬──────────────┬──────────┬──┘
           │              │              │              │          │
    ┌──────▼──┐    ┌──────▼──┐    ┌─────▼──┐    ┌─────▼──┐  ┌───▼────┐
    │  WAN    │    │ PUBLIC  │    │PRIVATE │    │ SYSTEM │  │  DATA  │
    │Internet │    │10.N.0.x │    │10.N.1.x│    │10.N.2.x│  │10.N.3.x│
    └─────────┘    └──┬──────┘    └──┬─────┘    └──┬─────┘  └──┬─────┘
                      │              │              │            │
               ┌──────▼──────┐  ┌───▼──────────────┼────────┐  │
               │ Nginx proxy │  │  RKE2 K8s Cluster│        │  │
               │ 10.N.0.10   │  │                  │        │  │
               │             │  │  ┌─────────────┐ │        │  │
               │  :443 → K8s │  │  │  kgateway   │ │        │  │
               │  NodePort   │  │  │ (Envoy)     │ │        │  │
               └─────────────┘  │  └──────┬──────┘ │        │  │
                                │         │routes  │        │  │
                                │  ┌──────▼──┐     │        │  │
                                │  │Backstage│     │     ┌──▼──────┐
                                │  │(portal) │     │     │  Redis  │
                                │  └─────────┘     │     │10.N.2.10│
                                │  ┌──────────┐    │     └─────────┘
                                │  │ Choreo   │    │     ┌─────────┐
                                │  │ API +    │    │     │Registry │
                                │  │ Ctrl Mgr │    │     │10.N.2.12│
                                │  └──────────┘    │     └─────────┘
                                │  ┌──────────┐    │
                                │  │ Thunder  │    │  ┌──────────────┐
                                │  │  (IdP)   │    │  │  PG Primary  │
                                │  └──────────┘    │  │  10.N.3.10   │
                                │  ┌──────────┐    │  ├──────────────┤
                                │  │Data plane│    │  │  PG Standby  │
                                │  │  agent   │    │  │  10.N.3.11   │
                                │  │Cluster GW│    │  └──────────────┘
                                │  └──────────┘    │
                                └──────────────────┘
```

### Reserved IPs quick reference

| Service | VLAN | Static IP | DNS name (via VyOS) | K8s cluster DNS |
|---------|------|-----------|---------------------|-----------------|
| Nginx LB proxy | PUBLIC | `10.N.0.10` | `choreo.sre-N.internal` | — |
| Redis / KV | SYSTEM | `10.N.2.10` | `redis.sre-N.internal` | `redis.default.svc.cluster.local` |
| Container registry | SYSTEM | `10.N.2.12` | `registry.sre-N.internal` | `registry.default.svc.cluster.local` |
| PostgreSQL primary | DATA | `10.N.3.10` | `postgres.sre-N.internal` | `postgres.default.svc.cluster.local` |
| PostgreSQL standby | DATA | `10.N.3.11` | `postgres-ro.sre-N.internal` | `postgres-ro.default.svc.cluster.local` |

---

## Integration 1 — PostgreSQL (DATA VLAN)

### What uses it
- **Backstage** — developer portal stores component catalogue, users, and API entities
- **Thunder** — OAuth2/OIDC identity provider stores clients, tokens, and consent records

### Connection flow

```
Thunder pod / Backstage pod
  │
  │  1. DNS: postgres.default.svc.cluster.local
  ▼
CoreDNS (in-cluster)
  │
  │  2. Resolves Service → ClusterIP (e.g. 10.96.4.22)
  ▼
kube-proxy iptables DNAT rule
  │
  │  3. ClusterIP → Endpoints → 10.N.3.10:5432
  ▼
K8s node NIC (PRIVATE VLAN 10.N.1.x)
  │
  │  4. Packet: src=10.N.1.x  dst=10.N.3.10:5432
  │     Node's default gateway = VyOS PRIVATE interface (10.N.1.1)
  ▼
VyOS — PRIV-TO-DATA ruleset
  │
  │  5. Rule 10: accept established/related
  │     Rule 20: accept TCP dst-port 5432  ← PostgreSQL
  ▼
PostgreSQL VM — DATA VLAN 10.N.3.10
  │
  │  6. pg_hba.conf: host all all 10.N.1.0/24 md5  → accept
  ▼
  Connection established
```

### DNS resolution detail

VyOS registers the static IP in dnsmasq **before the VM is even deployed**:
```vyos
set system static-host-mapping host-name 'postgres.sre-N.internal' inet '10.N.3.10'
set system static-host-mapping host-name 'postgres-ro.sre-N.internal' inet '10.N.3.11'
```
(`cloudinit.tf` lines 41-42)

For K8s pods, the cluster DNS name goes through an additional K8s layer:
```
postgres.default.svc.cluster.local
  → ClusterIP (virtual)
    → Endpoints object (10.N.3.10)
      → Real VM
```
This is why you need `kubernetes_service_v1` + `kubernetes_endpoints_v1` even though
there is no pod backing it — the Service gives pods a stable cluster DNS name and the
Endpoints object tells K8s where to actually send the packets.

### Terraform files

| File | What it does |
|------|-------------|
| `team-template/postgresql_ha.tf.example` | Creates PostgreSQL VMs with static IPs |
| `team-template/cloudinit.tf` | Registers `postgres.*` in VyOS static-host-mapping |
| `deployments/openchoreo/choreo_k8s_services.tf` | `kubernetes_service_v1` + `kubernetes_endpoints_v1` |
| `deployments/openchoreo/choreo_k8s_setup.tf` | `kubernetes_secret_v1` with connection URL |
| `deployments/openchoreo/locals.tf` | Builds connection string using `cidrhost()` |

### VyOS firewall rule

```
Ruleset:  PRIV-TO-DATA
Rule 20:  action=accept  protocol=tcp  dst-port=5432
Applied:  zone DATA from PRIVATE
```

### Connection strings used in Terraform

```
Thunder:   postgresql://thunder:<pw>@postgres.default.svc.cluster.local:5432/thunder
Backstage: postgresql://backstage:<pw>@postgres.default.svc.cluster.local:5432/backstage
```
(defined in `deployments/openchoreo/locals.tf`, stored as K8s secrets)

### Verify

```bash
# From inside the K8s cluster — test end-to-end connectivity
kubectl run pg-test -n choreo-system --image=postgres:16 --restart=Never -it --rm -- \
  psql "postgresql://thunder:<pw>@postgres.default.svc.cluster.local:5432/thunder" \
  -c "SELECT version();"

# Check the Endpoints object has the right IP
kubectl get endpoints postgres -n default
# ADDRESS should be 10.N.3.10

# From VyOS — verify DNS is resolving
show system static-host-mapping
dig @127.0.0.1 postgres.sre-N.internal
```

---

## Integration 2 — KV Store / Redis (SYSTEM VLAN)

### What uses it
- **Application workloads** deployed via OpenChoreo (session cache, rate-limit counters, pub/sub)
- OpenChoreo v0.16 itself does **not** require Redis — kgateway handles rate limiting natively
- Future workloads deployed onto the cluster can use the K8s cluster DNS name

### Connection flow

```
Application pod (PRIVATE VLAN)
  │
  │  1. DNS: redis.default.svc.cluster.local:6379
  ▼
CoreDNS → ClusterIP → Endpoints → 10.N.2.10:6379
  │
  │  2. Packet leaves K8s node with dst=10.N.2.10:6379
  ▼
VyOS — PRIV-TO-SYS ruleset
  │
  │  3. Rule 10: accept established/related
  │     Rule 40: accept TCP dst-port <kv_store_port>   (6379 Redis / 8500 Consul)
  ▼
Redis VM — SYSTEM VLAN 10.N.2.10
  │
  │  4. Redis binds 0.0.0.0 — accepts connection
  ▼
  Connection established
```

### DNS resolution detail

VyOS static-host-mapping:
```vyos
set system static-host-mapping host-name 'redis.sre-N.internal' inet '10.N.2.10'
```
(`cloudinit.tf` line 43)

For K8s pods, use the cluster-native name from `service_dns.tf.example`:
```
redis.default.svc.cluster.local:6379
  → ClusterIP → Endpoints (10.N.2.10) → Redis VM
```

### Terraform files

| File | What it does |
|------|-------------|
| `team-template/kv_store.tf.example` | Creates Redis VM with static IP `10.N.2.10` |
| `team-template/cloudinit.tf` | Registers `redis.*` in VyOS static-host-mapping |
| `team-template/service_dns.tf.example` | `kubernetes_service_v1` + `kubernetes_endpoints_v1` for redis |
| `team-template/variables.tf` | `kv_store_port` variable (default 6379) |

### VyOS firewall rule

```
Ruleset:  PRIV-TO-SYS
Rule 40:  action=accept  protocol=tcp  dst-port=<kv_store_port>
Applied:  zone SYSTEM from PRIVATE
```

The port is parameterised — change `kv_store_port = 8500` in `terraform.tfvars`
to switch to Consul without touching the firewall config.

### Connection strings

```
From K8s pod:  redis://redis.default.svc.cluster.local:6379
From any VM:   redis://redis.sre-N.internal:6379
```

### Add Redis to an OpenChoreo-deployed app

If you deploy an application via OpenChoreo that needs Redis, set the environment
variable in its component configuration:

```yaml
# OpenChoreo component environment variables
env:
  - name: REDIS_URL
    value: "redis://redis.default.svc.cluster.local:6379"
```

### Verify

```bash
# Check Endpoints
kubectl get endpoints redis -n default
# ADDRESS should be 10.N.2.10

# Test from a pod
kubectl run redis-test --image=redis:7 --restart=Never -it --rm -- \
  redis-cli -h redis.default.svc.cluster.local ping
# Expected: PONG

# From VyOS
dig @127.0.0.1 redis.sre-N.internal
# Expected: 10.N.2.10
```

---

## Integration 3 — Container Registry (SYSTEM VLAN)

### What uses it
- **RKE2 nodes** — containerd pulls workload images at pod scheduling time
- **OpenChoreo build plane** — pushes built images after CI runs (optional)
- Applications deployed via OpenChoreo reference images from this registry

### IP and DNS

Reserved IP: `10.N.2.12` (SYSTEM VLAN, `.12` offset)

Register in VyOS by adding to `extra_service_dns` in your team VPC `terraform.tfvars`:
```hcl
extra_service_dns = {
  # ... existing choreo entries ...
  "registry" = "10.N.2.12"   # Container registry in SYSTEM VLAN
}
```

After `terraform apply`, VyOS serves:
- `registry.sre-N.internal` → `10.N.2.12`

### Connection flow

```
K8s node containerd (PRIVATE VLAN)
  │
  │  1. Image pull: registry.sre-N.internal:5000/myapp:latest
  │     containerd resolves via node's DNS → VyOS PRIVATE gateway
  ▼
VyOS DNS (dnsmasq)
  │
  │  2. static-host-mapping: registry.sre-N.internal → 10.N.2.12
  ▼
VyOS — PRIV-TO-SYS ruleset
  │
  │  3. Rule 30: accept TCP dst-port 5000,443  ← Container Registry
  ▼
Registry VM — SYSTEM VLAN 10.N.2.12
  │
  │  4. Docker Registry v2 / Harbor serves the image layers
  ▼
  Image pulled, pod starts
```

### VyOS firewall rule

```
Ruleset:  PRIV-TO-SYS
Rule 30:  action=accept  protocol=tcp  dst-port=5000,443
Applied:  zone SYSTEM from PRIVATE
```

Port 5000 = Docker Registry v2 (HTTP/HTTPS).
Port 443 = Harbor or any registry serving on standard HTTPS.

### Provisioning the registry VM

Create a `registry.tf` in your team workspace (alongside `kv_store.tf`):

```hcl
# registry.tf — Docker Registry v2 in SYSTEM VLAN
locals {
  registry_ip     = cidrhost(var.vlans.system.cidr, 12)   # 10.N.2.12
  registry_prefix = split("/", var.vlans.system.cidr)[1]
}

resource "harvester_cloudinit_secret" "registry" {
  name      = "registry-cloudinit"
  namespace = var.namespace

  network_data = <<-NETDATA
    version: 2
    ethernets:
      enp1s0:
        addresses:
          - ${local.registry_ip}/${local.registry_prefix}
        gateway4: ${var.vlans.system.gateway}
        nameservers:
          addresses: [${var.vlans.system.gateway}]
          search: [${var.dns_domain}]
  NETDATA

  user_data = <<-USERDATA
    #cloud-config
    hostname: registry
    fqdn: registry.${var.dns_domain}
    manage_etc_hosts: true
    packages: [docker.io]
    runcmd:
      - systemctl enable --now docker
      - docker run -d --restart=always --name registry \
          -p 5000:5000 \
          -v /var/lib/registry:/var/lib/registry \
          registry:2
    ssh_authorized_keys:
      - ${var.ssh_public_key}
  USERDATA
}
```

### Configuring K8s nodes to trust the registry

RKE2 uses containerd. Add the registry mirror to the RKE2 node cloud-init
(in `rke2_cluster.tf.example`, inside the `runcmd` or `write_files` block):

```yaml
write_files:
  # Tell containerd to use the internal registry
  - path: /etc/rancher/rke2/registries.yaml
    content: |
      mirrors:
        "registry.sre-N.internal:5000":
          endpoint:
            - "http://registry.sre-N.internal:5000"
      configs:
        "registry.sre-N.internal:5000":
          tls:
            insecure_skip_verify: true   # for self-signed / HTTP registry
```

For a TLS-enabled registry, add the CA certificate instead of skipping verification:
```yaml
      configs:
        "registry.sre-N.internal:443":
          tls:
            ca_file: "/etc/ssl/registry-ca.crt"
```

### K8s Service + Endpoints (for cluster DNS name)

Add to `service_dns.tf` or `choreo_k8s_services.tf`:

```hcl
resource "kubernetes_service_v1" "registry" {
  metadata { name = "registry", namespace = "default" }
  spec {
    port { name = "registry", port = 5000, target_port = 5000, protocol = "TCP" }
  }
}

resource "kubernetes_endpoints_v1" "registry" {
  metadata { name = "registry", namespace = "default" }
  subset {
    address { ip = cidrhost(var.vlans.system.cidr, 12) }
    port    { name = "registry", port = 5000, protocol = "TCP" }
  }
}
```

After applying, pods reference images as:
```
registry.default.svc.cluster.local:5000/myapp:latest
```

### Verify

```bash
# Test registry is reachable from a K8s node (SSH to a worker)
curl http://registry.sre-N.internal:5000/v2/

# Push and pull test
docker pull alpine
docker tag alpine registry.sre-N.internal:5000/alpine:test
docker push registry.sre-N.internal:5000/alpine:test

# Pull from inside K8s
kubectl run reg-test --image=registry.sre-N.internal:5000/alpine:test \
  --restart=Never --command -- echo "image pulled OK"
kubectl logs reg-test
```

---

## Integration 4 — External Request Flow

This covers how a browser or API client outside the network reaches OpenChoreo
components, and how the request is routed to the correct pod inside K8s.

### Full path — HTTPS request to the developer portal

```
Browser: GET https://choreo.sre-N.internal/
  │
  │  DNS resolves choreo.sre-N.internal → 10.N.0.10  (VyOS static-host-mapping)
  │
  ▼
[1] Internet / management network
  │  TCP :443 → 10.N.0.10
  ▼
[2] VyOS WAN-TO-PUBLIC ruleset
  │  Rule 20: accept TCP dst-port 80,443  ← allows HTTPS inbound
  │  (if coming from WAN/internet)
  ▼
[3] Nginx proxy VM — PUBLIC VLAN 10.N.0.10
  │
  │  Terminates TLS (wildcard cert for *.sre-N.internal)
  │  Reads Host header: "choreo.sre-N.internal"
  │  Selects upstream: kgateway_backend → 10.N.1.x:30443
  ▼
[4] VyOS PUB-TO-PRIV ruleset
  │  Rule 20: accept TCP dst-port 30000-32767  ← NodePort range
  ▼
[5] RKE2 worker node — PRIVATE VLAN 10.N.1.x  port 30443
  │
  │  kube-proxy iptables: NodePort 30443 → kgateway ClusterIP
  ▼
[6] kgateway (Envoy proxy pod)
  │
  │  Reads Host header → routes to backend Service by HTTPRoute rule:
  │    choreo.sre-N.internal     → backstage:3000
  │    choreo-api.sre-N.internal → openchoreo-api:8080
  │    choreo-id.sre-N.internal  → thunder:8080
  ▼
[7] Target pod (Backstage / OpenChoreo API / Thunder)
  │
  │  Processes request, returns response
  ▼
Response travels back through the same path in reverse
```

### Hostname routing table

kgateway uses Gateway API `HTTPRoute` resources to route by `Host` header.
OpenChoreo's Helm chart creates these automatically based on the `global.*Url` values.

| Host header | Routed to | K8s Service | Port |
|-------------|-----------|-------------|------|
| `choreo.sre-N.internal` | Backstage developer portal | `backstage` | 3000 |
| `choreo-api.sre-N.internal` | OpenChoreo API server | `openchoreo-api` | 8080 |
| `choreo-id.sre-N.internal` | Thunder OAuth2/OIDC IdP | `thunder` | 8080 |

### VyOS firewall rules involved

| Step | Ruleset | Rule | What it allows |
|------|---------|------|---------------|
| Internet → Nginx | `WAN-TO-PUBLIC` | Rule 20 | TCP 80, 443 inbound to PUBLIC VLAN |
| Nginx → kgateway | `PUB-TO-PRIV` | Rule 20 | TCP 30000-32767 (NodePort range) |
| Rancher → K8s API | `WAN-TO-PRIV` | Rule 20 | TCP 6443 from `rancher_mgmt_cidr` only |
| Return traffic | `WAN-RETURN` | Rule 10 | Established/related connections back |

### Internal service-to-service flows

Within the K8s cluster (all pods in PRIVATE VLAN — no VyOS involved):

```
OpenChoreo API ──→ Thunder (token validation)
  thunder.choreo-system.svc.cluster.local:8443

Backstage ──→ OpenChoreo API (fetch component data)
  openchoreo-api.choreo-system.svc.cluster.local:8080

Data plane agent ──→ Control plane (Cluster Gateway WebSocket)
  openchoreo-api.choreo-system.svc.cluster.local:8443
```

These are pod-to-pod connections through K8s cluster networking (Calico CNI).
They never leave the K8s cluster, so no VyOS routing or firewall rules apply.

### Cluster Gateway (WebSocket — port 8443)

The OpenChoreo data plane maintains a persistent WebSocket connection to the
control plane for real-time cluster management commands.

```
Data plane agent pod
  │
  │  WebSocket: wss://openchoreo-api.choreo-system.svc.cluster.local:8443
  ▼
Cluster Gateway pod (control plane side)
  │
  │  Receives: component deployments, scaling events, health status
  │  Sends:    reconciliation commands back to data plane
```

This is cluster-internal only. If you deploy multi-cluster (separate data plane
in another K8s cluster), the Cluster Gateway WebSocket would cross a network boundary
and require a path through VyOS or a separate network path.

### TLS termination map

| Hop | TLS handled by | Certificate |
|-----|---------------|-------------|
| Client → Nginx | Nginx (`ssl_certificate`) | Wildcard `*.sre-N.internal` (your cert) |
| Nginx → kgateway | `proxy_ssl_verify off` | kgateway uses cert-manager internal CA |
| kgateway → pods | cert-manager `internal-ca` ClusterIssuer | Auto-issued per service |
| Thunder → DB | None (PostgreSQL `sslmode=disable`) | Plain TCP inside VLAN |

---

## Full Cross-Zone Traffic Summary

```
Source ──────────────────────────────→ Destination    Protocol   VyOS Ruleset
─────────────────────────────────────────────────────────────────────────────
Internet                             → Nginx proxy    TCP 443    WAN-TO-PUBLIC r20
Nginx proxy (PUBLIC)                 → kgateway       TCP 30443  PUB-TO-PRIV r20
Rancher (mgmt net)                   → RKE2 API       TCP 6443   WAN-TO-PRIV r20
K8s pods (PRIVATE)                   → PostgreSQL     TCP 5432   PRIV-TO-DATA r20
K8s pods (PRIVATE)                   → Redis          TCP 6379   PRIV-TO-SYS r40
K8s pods (PRIVATE)                   → Registry       TCP 5000   PRIV-TO-SYS r30
K8s pods (PRIVATE)                   → Vault          TCP 8200   PRIV-TO-SYS r20
Vault (SYSTEM)                       → PostgreSQL     TCP 5432   SYS-TO-DATA r20
All VLANs                            → Internet       any        ALLOW-INTERNET
─────────────────────────────────────────────────────────────────────────────
K8s pod → K8s pod (same cluster)     any              (Calico CNI — no VyOS)
```

---

## Troubleshooting Integration Issues

### Pod can't reach PostgreSQL

```bash
# 1. Check the Endpoints object has the right IP
kubectl get endpoints postgres -n default -o wide
# If empty or wrong IP, re-apply choreo_k8s_services.tf

# 2. Test TCP connectivity from inside the cluster
kubectl run nettest --image=busybox --restart=Never -it --rm -- \
  nc -zv 10.N.3.10 5432
# "open" = firewall OK;  "Connection refused" = PG not listening

# 3. Check VyOS firewall allows the traffic
ssh vyos@192.168.1.N0
show firewall ipv4 name PRIV-TO-DATA
# Rule 20 should show non-zero packet count after a connection attempt
```

### Pod can't reach Redis

```bash
# Same pattern — check PRIV-TO-SYS rule 40
kubectl run nettest --image=busybox --restart=Never -it --rm -- \
  nc -zv 10.N.2.10 6379

ssh vyos@192.168.1.N0
show firewall ipv4 name PRIV-TO-SYS
```

### K8s node can't pull from registry

```bash
# On the RKE2 worker node
crictl pull registry.sre-N.internal:5000/alpine:test

# If it fails with "connection refused": check PRIV-TO-SYS rule 30
# If it fails with "certificate error": add insecure_skip_verify or CA cert
#   to /etc/rancher/rke2/registries.yaml and restart rke2-agent

# Check containerd can resolve the hostname
nslookup registry.sre-N.internal 10.N.1.1    # query VyOS private gateway
```

### External request not reaching Backstage

Work through the chain one hop at a time:

```bash
# Hop 1 — DNS resolves to Nginx IP
dig choreo.sre-N.internal
# Expected: 10.N.0.10

# Hop 2 — Nginx is reachable
curl -k https://choreo.sre-N.internal/    # from outside

# Hop 3 — Nginx can reach kgateway NodePort (run on Nginx VM)
ssh ubuntu@10.N.0.10
curl -k https://10.N.1.101:30443 -H "Host: choreo.sre-N.internal"

# Hop 4 — kgateway routes to Backstage
kubectl get httproute -n choreo-system
# Each route shows the backend service and port

# Hop 5 — Backstage pod is running and healthy
kubectl get pods -n choreo-system -l app.kubernetes.io/name=backstage
kubectl logs -n choreo-system deploy/backstage --tail=50
```

### Internal service-to-service (e.g. API → Thunder OIDC)

```bash
# All inter-pod traffic is direct cluster networking — VyOS is NOT involved
# Check that Thunder's ClusterIP service is reachable
kubectl exec -n choreo-system deploy/openchoreo-api -- \
  wget -qO- http://thunder.choreo-system.svc.cluster.local:8080/.well-known/openid-configuration
```
