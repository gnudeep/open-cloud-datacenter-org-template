# Harvester Multi-Team VPC Platform

Terraform infrastructure for creating **VPC-like network isolation** on [Harvester HCI 1.7.1](https://harvesterhci.io/).
Each SRE team gets a dedicated VyOS router VM and four VLAN-backed zones — effectively a private cloud network slice
with routing, firewall, NAT, DHCP, and DNS all managed as code.

---

## Who Should Read What

The repo serves two distinct audiences with different entry points:

| You are… | Start here | Then read |
|---|---|---|
| **Platform team** setting up the cluster for the first time | [`infra/`](#infra--platform-team-runs-once) | [`WORKFLOW.md`](./WORKFLOW.md) § Platform Setup |
| **SRE team** creating your team's VPC | [`team-template/`](#team-template--each-sre-team-copies-this) | [`WORKFLOW.md`](./WORKFLOW.md) § SRE Team Onboarding |
| **SRE team** deploying an application | [`deployments/`](#deployments--application-deployment-guides) | The guide for your app |
| **Anyone** wanting a deep technical reference | [`AGENT.md`](./AGENT.md) | — |
| **Anyone** looking for day-2 procedures | [`WORKFLOW.md`](./WORKFLOW.md) | — |

---

## Repository Structure

```
lk-dc-org-template/
│
├── infra/                          # Platform team — run ONCE per cluster
│   ├── main.tf                     # ClusterNetwork + per-node VLANConfig
│   ├── namespaces_rbac.tf          # K8s Namespaces, ServiceAccounts, RBAC
│   ├── rancher.tf                  # Rancher server registration
│   ├── variables.tf                # Team roster (add a team = one new map entry)
│   ├── terraform.tfvars.example
│   ├── outputs.tf
│   └── kyverno/
│       └── vlan-policy.yaml        # Admission controller — prevents VLAN conflicts
│
├── team-template/                  # SRE teams — copy this per team
│   ├── provider.tf                 # Harvester + Rancher providers
│   ├── variables.tf                # All team-specific inputs (namespace, VLANs, …)
│   ├── networks.tf                 # Four VLAN-backed VM networks
│   ├── vyos_router.tf              # VyOS router VM (5 NICs — 1 mgmt + 4 VLANs)
│   ├── cloudinit.tf                # Full VyOS config: firewall, NAT, DHCP, DNS
│   ├── images.tf                   # VyOS image resource
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   │
│   └── *.tf.example                # Workload blueprints (copy → rename to .tf)
│       ├── rke2_cluster.tf.example     RKE2 Kubernetes cluster in PRIVATE VLAN
│       ├── postgresql_ha.tf.example    PostgreSQL primary + standby in DATA VLAN
│       ├── kv_store.tf.example         Redis or Consul in SYSTEM VLAN
│       ├── workload_vms.tf.example     Generic VM examples for each zone
│       ├── service_dns.tf.example      Extra VyOS DNS entries
│       └── coredns_stub_zone.tf.example  CoreDNS stub zone for internal DNS
│
├── deployments/                    # Application deployment guides + Terraform
│   ├── README.md                   # Guide index and common prerequisites
│   ├── openchoreo.md               # OpenChoreo v0.16+ step-by-step guide
│   ├── openchoreo-integrations.md  # How every OpenChoreo service connects
│   └── openchoreo/                 # Standalone Terraform workspace for OpenChoreo
│       ├── README.md
│       ├── variables.tf
│       ├── terraform.tfvars.example
│       ├── nginx_lb.tf             # Nginx proxy VM in PUBLIC VLAN
│       ├── choreo_prereqs.tf       # cert-manager, Gateway API CRDs
│       ├── thunder.tf              # Thunder IdP Helm release
│       ├── openchoreo_cp.tf        # OpenChoreo control plane Helm release
│       ├── openchoreo_dp.tf        # OpenChoreo data plane Helm release
│       ├── choreo_k8s_setup.tf     # K8s secrets (TLS, DB creds, OIDC)
│       ├── choreo_k8s_services.tf  # Service+Endpoints for PostgreSQL, CoreDNS stub
│       └── outputs.tf
│
├── scripts/
│   └── audit-vlans.sh              # Detect VLAN assignment conflicts across namespaces
│
│── AGENT.md                        # Full technical reference (architecture, IPs, rules)
│── WORKFLOW.md                     # Step-by-step procedures for all operations
│
└── (root *.tf files)               # Single-team baseline — see note below
    ├── provider.tf
    ├── variables.tf
    ├── cluster_network.tf
    ├── networks.tf
    ├── images.tf
    ├── cloudinit.tf
    ├── vyos_router.tf
    └── outputs.tf
```

> **Note — root `.tf` files**: These are the original single-team baseline from which the
> multi-team architecture evolved. They deploy a single VPC (sre-alpha defaults) and are useful
> as a quick-start or reference. For a real multi-team deployment **use `infra/` + `team-template/`
> instead** — they include namespace isolation, RBAC, and VLAN conflict protection.

---

## Architecture Overview

```
                      Internet
                          │
              ┌───────────┴───────────┐
              │  Basic FW / Gateway   │  (192.168.1.1)
              └───────────┬───────────┘
                          │ Management network (192.168.1.0/24)
                          │
              ┌───────────┴───────────┐
              │     VyOS Router VM    │  one per SRE team
              │  (firewall, NAT,      │  management IP: 192.168.1.N*10
              │   DHCP, DNS, routing) │
              └──┬──────┬──────┬──────┘
                 │      │      │      │
           VLAN 100  VLAN 200  VLAN 300  VLAN 400
           PUBLIC    PRIVATE   SYSTEM    DATA
           10.N.0/24 10.N.1/24 10.N.2/24 10.N.3/24
           LBs/Nginx K8s nodes Vault/Reg PG/Kafka
```

Where **N** is the team's offset (sre-alpha = 1, sre-beta = 2, …). Each team's four VLANs are
fully isolated from every other team's VLANs at Layer 2.

### VLAN allocation formula

| Team | N | public VLAN | private VLAN | system VLAN | data VLAN | Subnet block |
|---|---|---|---|---|---|---|
| sre-alpha | 1 | 100 | 200 | 300 | 400 | 10.1.0.0/22 |
| sre-beta  | 2 | 110 | 210 | 310 | 410 | 10.2.0.0/22 |
| sre-gamma | 3 | 120 | 220 | 320 | 420 | 10.3.0.0/22 |

### Zone purpose and what goes where

| Zone | VLAN range | Typical workloads | VyOS interface |
|---|---|---|---|
| **PUBLIC** | 100, 110, 120 … | Nginx LB, MetalLB pool, NAT exit IPs | `eth1.<vlan>` |
| **PRIVATE** | 200, 210, 220 … | RKE2 K8s nodes, app VMs | `eth2.<vlan>` |
| **SYSTEM** | 300, 310, 320 … | Redis, Vault, container registry | `eth3.<vlan>` |
| **DATA** | 400, 410, 420 … | PostgreSQL primary/standby, Kafka | `eth4.<vlan>` |

### Traffic matrix (per-team firewall policy)

| Source → Dest | PUBLIC | PRIVATE | SYSTEM | DATA |
|---|---|---|---|---|
| **WAN (internet)** | ✅ 80, 443 | ❌ | ❌ | ❌ |
| **PUBLIC** | — | ✅ NodePort 30000-32767 | ❌ | ❌ |
| **PRIVATE** | ❌ | — | ✅ 6379, 8200, 5000 | ✅ 5432, 9092 |
| **SYSTEM** | ❌ | ❌ | — | ✅ 5432 |
| **DATA** | ❌ | ❌ | ❌ | — |

---

## Two-Layer Management Model

The platform is managed by two distinct roles with different scopes:

```
Platform Team                         SRE Teams
─────────────────────────────         ─────────────────────────────────────
infra/                                team-template/   (one copy per team)
  ├─ ClusterNetwork (vpc-trunk)         ├─ VyOS router VM
  ├─ VLANConfig (per node)             ├─ 4 VLAN networks
  ├─ Namespace (sre-alpha, …)          ├─ Firewall / NAT / DHCP / DNS
  ├─ ServiceAccount + RBAC             └─ Workloads: K8s, DBs, KV, …
  └─ Kyverno VLAN policy

Cluster-scoped resources               Namespace-scoped resources
Run once, affects all teams            Run per team, isolated from others
```

**Key rule:** SRE teams operate entirely within their namespace. They cannot create or modify
`ClusterNetwork` or `VLANConfig` resources (cluster-scoped). The Kyverno admission controller
enforces that each team can only create networks on the VLANs assigned to them.

---

## Quick Start

### Platform team (first-time setup)

```bash
cd infra/
cp terraform.tfvars.example terraform.tfvars
# Edit: add team entries, set harvester_kubeconfig, node names, etc.
terraform init
terraform apply
# This creates: ClusterNetwork, VLANConfig, Namespaces, RBAC, Kyverno policy
```

### SRE team (create your VPC)

```bash
cp -r team-template/ my-team-vpc/
cd my-team-vpc/
cp terraform.tfvars.example terraform.tfvars
# Edit: set namespace, vlans (IDs and CIDRs allocated by platform team), ssh_public_key, etc.
terraform init
terraform apply
# This creates: VyOS router VM + 4 VLAN networks; VyOS auto-configures firewall/NAT/DHCP/DNS
```

### Verify VyOS is healthy

```bash
ssh vyos@192.168.1.<N*10>
show interfaces
show firewall zone-policy
show dhcp server leases
show ip route
```

### Deploy a workload

Copy a `.tf.example` file from `team-template/` into your VPC workspace and apply:

```bash
cp team-template/postgresql_ha.tf.example my-team-vpc/postgresql_ha.tf
# Edit: set pg_password, pg_replication_password in terraform.tfvars
cd my-team-vpc/ && terraform apply
```

See [`deployments/README.md`](./deployments/README.md) for full application deployment guides.

---

## Prerequisites

- Harvester HCI 1.7.1 cluster (3+ nodes recommended)
- Physical switch configured with VLAN trunk (allows VLANs 100–490)
- Terraform >= 1.5.0
- `kubectl` configured for the Harvester management cluster (for `infra/`)
- Helm 3 (for `deployments/openchoreo/`)

---

## VLAN Conflict Protection (three-layer defence)

The platform prevents two teams from accidentally using the same VLAN ID:

1. **Terraform validation** (`team-template/variables.tf`) — `validation` blocks catch wrong VLAN zone assignments at `plan` time.
2. **Kyverno admission controller** (`infra/kyverno/vlan-policy.yaml`) — blocks non-compliant network creation at the Kubernetes API level using per-namespace annotations as the source of truth.
3. **Audit script** (`scripts/audit-vlans.sh`) — periodic detective control; exit code = number of conflicts found. Run in CI or cron.

---

## Key Documents

| Document | Purpose |
|---|---|
| [`AGENT.md`](./AGENT.md) | Deep technical reference: full IP scheme, firewall rules, DNS config, VLAN formula, provider versions, all Terraform resources explained |
| [`WORKFLOW.md`](./WORKFLOW.md) | Operational playbook: onboarding, day-2 operations, offboarding, troubleshooting — step-by-step for both platform and SRE teams |
| [`deployments/README.md`](./deployments/README.md) | Index of application deployment guides with prerequisites |
| [`deployments/openchoreo.md`](./deployments/openchoreo.md) | Full OpenChoreo v0.16+ deployment guide on this platform |
| [`deployments/openchoreo-integrations.md`](./deployments/openchoreo-integrations.md) | How OpenChoreo services (PostgreSQL, Redis, Registry, external traffic) connect across VLANs |
