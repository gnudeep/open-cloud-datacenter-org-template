# Multi-Team SRE VLAN Platform — Agent Reference

> **Hypervisor:** Harvester HCI 1.7.1
> **IaC:** Terraform >= 1.5.0
> **Providers:** harvester/harvester ~> 1.7 | rancher/rancher2 ~> 13.1 | hashicorp/kubernetes ~> 2.35
> **Pattern:** Namespace-isolated VPC-per-team, shared cluster network trunk

---

## 1. Architecture Overview

```
Internet → Basic FW (192.168.1.1)
                │
                ▼
        Harvester HCI Cluster (3+ nodes)
        Physical trunk: eth1 → vpc-trunk ClusterNetwork
                │
    ┌───────────┼───────────┬─────────────┐
    │           │           │             │
  sre-alpha   sre-beta   sre-gamma    sre-delta
  namespace   namespace  namespace    namespace
    │           │           │             │
  VyOS-α      VyOS-β     VyOS-γ       VyOS-δ
  .10         .20         .30          .40
    │
  ┌─┬─┬─┐
  │ │ │ │
  P Pr S D   ← VLAN zones (public, private, system, data)
```

**Two-layer model:**

| Layer | Who manages | Resources |
|-------|------------|-----------|
| **Platform** (infra/) | Platform/Infra team | ClusterNetwork, VLANConfig per node, Namespaces, RBAC |
| **Team** (team-template/) | Each SRE team | VLAN Networks, VyOS Router VM, SSH Keys, Workload VMs |

---

## 2. VLAN Allocation Table

Each team receives a block of **4 VLANs** and a **/22 subnet block**.

| Team | Namespace | Offset | Public VLAN | Private VLAN | System VLAN | Data VLAN | Subnet Block | VyOS Mgmt IP |
|------|-----------|--------|-------------|--------------|-------------|-----------|--------------|--------------|
| sre-alpha  | sre-alpha  | 1 | 100 | 200 | 300 | 400 | 10.1.0.0/22  | 192.168.1.10 |
| sre-beta   | sre-beta   | 2 | 110 | 210 | 310 | 410 | 10.2.0.0/22  | 192.168.1.20 |
| sre-gamma  | sre-gamma  | 3 | 120 | 220 | 320 | 420 | 10.3.0.0/22  | 192.168.1.30 |
| sre-delta  | sre-delta  | 4 | 130 | 230 | 330 | 430 | 10.4.0.0/22  | 192.168.1.40 |
| sre-epsilon| sre-epsilon| 5 | 140 | 240 | 340 | 440 | 10.5.0.0/22  | 192.168.1.50 |

**Formula for team N (1-based):**
```
public_vlan  = 100 + (N-1)*10
private_vlan = 200 + (N-1)*10
system_vlan  = 300 + (N-1)*10
data_vlan    = 400 + (N-1)*10
subnet_block = 10.N.0.0/22
vyos_mgmt_ip = 192.168.1.(N*10)
```

### Per-team subnet breakdown

Each `/22` block splits into 4 `/24` zones:

| Zone    | CIDR          | Gateway    | Purpose                                          |
|---------|---------------|------------|--------------------------------------------------|
| public  | 10.N.0.0/24   | 10.N.0.1   | Load balancers, ingress                          |
| private | 10.N.1.0/24   | 10.N.1.1   | RKE2 K8s cluster nodes (managed by Rancher)      |
| system  | 10.N.2.0/24   | 10.N.2.1   | KV Store (Redis/Consul), Vault, container registry |
| data    | 10.N.3.0/24   | 10.N.3.1   | PostgreSQL Primary-Standby, Kafka                |

---

## 3. Traffic Matrix (per team, within their VPC)

| Source → Dest | Public | Private | System | Data |
|---------------|--------|---------|--------|------|
| **WAN**       | ✅ 80,443 | ✅ 6443 from `rancher_mgmt_cidr` (Rancher→RKE2) | ❌ | ❌ |
| **Public**    | —      | ✅ NodePort 30000-32767 | ❌  | ❌   |
| **Private**   | ❌     | —       | ✅ Vault(8200), Registry(5000/443), KV(`kv_store_port`) | ✅ PG(5432), Kafka(9092) |
| **System**    | ❌     | ❌      | —      | ✅ PG(5432) — Vault DB backend |
| **Data**      | ❌     | ❌      | ❌     | —    |

> **WAN→PRIVATE note:** VyOS uses a dedicated `WAN-TO-PRIV` ruleset (not `WAN-RETURN`) so that
> Rancher can reach the RKE2 API server on port 6443 from the management network.
> The source is restricted to `var.rancher_mgmt_cidr` — do **not** open this to `0.0.0.0/0`.

> Cross-team traffic: **blocked by default**. Teams are fully isolated at VLAN level.

---

## 4. Repository Directory Structure

```
lk-dc-org-template/
├── AGENT.md                    ← This file (reference for agents and engineers)
│
├── infra/                      ← Platform team: run ONCE, cluster-scoped resources
│   ├── main.tf                 ← ClusterNetwork + VLANConfig per node
│   ├── namespaces_rbac.tf      ← Namespace + ServiceAccount + RoleBinding per team
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
└── team-template/              ← SRE teams: each team copies this and applies
    ├── provider.tf
    ├── variables.tf
    ├── networks.tf             ← 4 VLAN-backed VM networks
    ├── images.tf               ← VyOS image + SSH key
    ├── cloudinit.tf            ← VyOS firewall + routing config (KV, RKE2, PG rules)
    ├── vyos_router.tf          ← VyOS VM (5 NICs)
    ├── outputs.tf
    ├── workload_vms.tf.example      ← Generic workload VM example
    ├── rke2_cluster.tf.example      ← RKE2 K8s cluster in PRIVATE VLAN
    ├── postgresql_ha.tf.example     ← PostgreSQL Primary-Standby in DATA VLAN
    ├── kv_store.tf.example          ← Redis/Consul in SYSTEM VLAN
    └── terraform.tfvars.example
```

---

## 5. Platform Team Setup (One-Time)

> **Run this ONCE per Harvester cluster.** Platform admin only.

### 5.1 Prerequisites

- Harvester cluster admin kubeconfig at `~/.kube/harvester.yaml`
- Physical switch with trunk ports configured for all team VLANs
- Terraform >= 1.5.0
- Rancher API key (see step below)

### 5.1a Generate a Rancher API Key

Harvester embeds Rancher. The `infra/` module needs an API key to manage Rancher Projects and Namespaces.

1. Open the Harvester/Rancher UI: `https://<harvester-vip>/`
2. Click your user avatar (top-right) → **API Keys**
3. Click **Add Key** → set an expiry → **Create**
4. Copy both the **Access Key** (`token-xxxxx`) and **Secret Key**
5. Set them in `infra/terraform.tfvars`:
   ```hcl
   rancher_url        = "https://<harvester-vip>"
   rancher_access_key = "token-xxxxx"
   rancher_secret_key = "<secret>"
   rancher_insecure   = true   # if using self-signed cert
   rancher_cluster_id = "local"
   ```

> The `rancher_cluster_id` is `"local"` for resources on the Harvester cluster itself.
> To confirm: Rancher UI → Cluster Management → find your cluster → the ID in the URL (`c-xxxxx`).

### 5.2 Physical Switch Configuration

Add all team VLANs to the trunk before running Terraform:

```
! Cisco IOS example — adapt for your switch
vlan 100,110,120,130,140        ! public zone per team
vlan 200,210,220,230,240        ! private zone per team
vlan 300,310,320,330,340        ! system zone per team
vlan 400,410,420,430,440        ! data zone per team

interface range GigabitEthernet0/1-3   ! Harvester node uplinks
 switchport mode trunk
 switchport trunk allowed vlan 100,110,120,130,140,200,210,220,230,240,300,310,320,330,340,400,410,420,430,440
 spanning-tree portfast trunk
```

### 5.3 Deploy Platform Infrastructure

```bash
cd infra/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: add all team names and node list
terraform init
terraform plan
terraform apply
```

### 5.4 Generate Team Kubeconfigs

After platform apply, generate a scoped kubeconfig per team:

```bash
# For each team (replace TEAM_NAME with actual team name, e.g. sre-alpha)
TEAM_NAME="sre-alpha"
NAMESPACE="sre-${TEAM_NAME#sre-}"  # or just use the namespace directly

# Get the ServiceAccount token
SA_SECRET=$(kubectl --kubeconfig ~/.kube/harvester.yaml \
  get serviceaccount "${TEAM_NAME}-deployer" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.secrets[0].name}' 2>/dev/null)

# For Kubernetes 1.24+, create a token manually
TOKEN=$(kubectl --kubeconfig ~/.kube/harvester.yaml \
  create token "${TEAM_NAME}-deployer" \
  -n "${NAMESPACE}" \
  --duration=8760h)

# Get cluster info
CLUSTER_SERVER=$(kubectl --kubeconfig ~/.kube/harvester.yaml \
  config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl --kubeconfig ~/.kube/harvester.yaml \
  config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Write kubeconfig for team
cat > "kubeconfig-${TEAM_NAME}.yaml" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${CLUSTER_SERVER}
    certificate-authority-data: ${CA_DATA}
  name: harvester
contexts:
- context:
    cluster: harvester
    namespace: ${NAMESPACE}
    user: ${TEAM_NAME}-deployer
  name: ${TEAM_NAME}
current-context: ${TEAM_NAME}
users:
- name: ${TEAM_NAME}-deployer
  user:
    token: ${TOKEN}
EOF

echo "Kubeconfig written: kubeconfig-${TEAM_NAME}.yaml"
echo "Share this file securely with the ${TEAM_NAME} SRE team."
```

**Securely deliver** `kubeconfig-<team>.yaml` to each SRE team (use vault, 1password, or encrypted channel — never plain email).

---

## 6. SRE Team Onboarding (Per-Team)

> **Each SRE team follows these steps** to set up their isolated VPC.

### 6.1 What you receive from Platform team

- Scoped kubeconfig: `kubeconfig-sre-<yourteam>.yaml`
- Your VLAN allocation (see table in Section 2)
- Your subnet block (e.g., `10.2.0.0/22` for sre-beta)
- Your VyOS management IP (e.g., `192.168.1.20` for sre-beta)

### 6.2 Setup Steps

```bash
# 1. Copy the team template
cp -r team-template/ my-team-vpc/
cd my-team-vpc/

# 2. Configure your variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your team-specific values (see Section 6.3)

# 3. Point to your scoped kubeconfig
export KUBECONFIG=../kubeconfig-sre-<yourteam>.yaml

# 4. Initialize and apply
terraform init
terraform plan
terraform apply
```

### 6.3 terraform.tfvars Reference for Teams

Fill in the values the platform team provided:

```hcl
# ── Your scoped kubeconfig ──
harvester_kubeconfig = "../kubeconfig-sre-yourteam.yaml"

# ── Your namespace (platform team created this) ──
namespace = "sre-yourteam"

# ── Cluster network name (platform team created this — do not change) ──
cluster_network_name = "vpc-trunk"

# ── Harvester node names (ask platform team for the list) ──
harvester_node_names = [
  "harvester-node-0",
  "harvester-node-1",
  "harvester-node-2",
]
uplink_nics = ["eth1"]   # Physical NIC — ask platform team
bond_mode   = "active-backup"

# ── Your VLAN allocation (from platform team's table) ──
# Example for sre-beta (team offset=2):
vlans = {
  public = {
    vlan_id = 110          # 100 + (N-1)*10
    cidr    = "10.2.0.0/24"
    gateway = "10.2.0.1"
  }
  private = {
    vlan_id = 210          # 200 + (N-1)*10
    cidr    = "10.2.1.0/24"
    gateway = "10.2.1.1"
  }
  system = {
    vlan_id = 310          # 300 + (N-1)*10
    cidr    = "10.2.2.0/24"
    gateway = "10.2.2.1"
  }
  data = {
    vlan_id = 410          # 400 + (N-1)*10
    cidr    = "10.2.3.0/24"
    gateway = "10.2.3.1"
  }
}

# ── Management network ──
mgmt_network_gateway = "192.168.1.1"   # Platform-provided gateway
vyos_mgmt_ip         = "192.168.1.20"  # Your VyOS IP (from platform table)
vyos_mgmt_cidr       = "24"

# ── VyOS Router VM ──
vyos_cpu       = 2
vyos_memory    = "2Gi"
vyos_disk_size = "10Gi"

# ── Your SSH public key (for VyOS access) ──
ssh_public_key = "ssh-ed25519 AAAA... your-team-key"

# ── DNS ──
upstream_dns = ["8.8.8.8", "1.1.1.1"]
```

### 6.4 Verify Deployment

```bash
# SSH into your VyOS router
ssh vyos@192.168.1.<your-team-ip>

# Check all interfaces are up
show interfaces

# Check routing
show ip route

# Check firewall zones
show firewall zone-policy

# Check NAT
show nat source rules

# Check DHCP leases (as VMs join)
show dhcp server leases
```

### 6.5 Deploy Workload VMs

Use the provided `workload_vms.tf.example` as a reference.
Key: set `network_name` to the correct VLAN network:

```hcl
network_interface {
  name         = "nic-private"
  model        = "virtio"
  type         = "bridge"
  network_name = harvester_network.vpc_vlans["private"].id
}
```

---

## 7. RBAC Model

### What SRE teams CAN do (namespace-scoped)

| Resource | Action |
|----------|--------|
| VirtualMachine | create, read, update, delete |
| harvester_network (VM Networks) | create, read, update, delete |
| harvester_ssh_key | create, read, update, delete |
| harvester_cloudinit_secret | create, read, update, delete |
| harvester_image | create, read, update, delete |
| Secrets, ConfigMaps | create, read, update, delete |

### What SRE teams CANNOT do (cluster-scoped, platform only)

| Resource | Reason |
|----------|--------|
| harvester_clusternetwork | Shared trunk — affects all nodes |
| harvester_vlanconfig | Shared trunk — affects all nodes |
| Other teams' namespaces | Strict namespace isolation |
| Node/cluster management | Platform admin only |

### Harvester RBAC in Kubernetes terms

```
Namespace: sre-<team>
  ServiceAccount: sre-<team>-deployer
  RoleBinding: sre-<team>-edit
    roleRef: ClusterRole/edit     ← standard Kubernetes edit role
```

The `edit` ClusterRole grants full CRUD on namespace-scoped resources.
Cluster-scoped resources (ClusterNetwork, VLANConfig) require `cluster-admin`.

---

## 8. Harvester UI Access

Each team can optionally get UI access via Harvester's built-in auth:

1. Platform admin creates a Harvester user in the UI (or via Rancher)
2. Assign the user to their namespace with **Project Member** role
3. User logs into Harvester UI at `https://<harvester-vip>/`
4. They see only their namespace's VMs, networks, and images

---

## 9. Adding a New Team (Checklist)

When onboarding a new SRE team, platform admin follows this checklist:

```
Platform Admin Checklist — New Team Onboarding
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[ ] 1. Assign team offset N (next available integer)
[ ] 2. Calculate VLAN IDs and subnet block from formula in Section 2
[ ] 3. Add VLANs to physical switch trunk (per Section 5.2)
[ ] 4. Add team entry to infra/terraform.tfvars
[ ] 5. Run `terraform apply` in infra/ to create namespace + RBAC
[ ] 6. Generate scoped kubeconfig (per Section 5.4)
[ ] 7. Deliver to team: kubeconfig + VLAN allocation table row + this AGENT.md
[ ] 8. Team follows Section 6 to deploy their VPC
[ ] 9. Platform admin verifies no VLAN ID conflicts with existing teams
```

---

## 10. Troubleshooting

### VMs not getting DHCP

```bash
# On VyOS router
show dhcp server leases
show dhcp server statistics
# Check the correct interface is bound to DHCP
show configuration commands | grep dhcp
```

### VyOS router not reachable after apply

```bash
# On Harvester node (via kubectl)
kubectl get vmi -n sre-<team>
kubectl describe vmi vyos-vpc-router -n sre-<team>

# Check cloud-init completed
kubectl logs -n sre-<team> <virt-launcher-pod> -c compute
```

### Network not showing in Harvester

```bash
# Check NetworkAttachmentDefinition created
kubectl get net-attach-def -n sre-<team>

# Check ClusterNetwork and VLANConfig (platform level)
kubectl get clusternetwork
kubectl get vlanconfig
```

### VLAN traffic not passing between nodes

```bash
# Verify physical switch trunk includes the VLAN
# On each Harvester node, check the bond
ip link show
bridge vlan show

# Check VLANConfig applied
kubectl get vlanconfig -o yaml
```

### Terraform "namespace not found" error

The SRE team is trying to apply before the platform admin ran `infra/`. Platform must apply first. Verify:

```bash
kubectl get namespace sre-<team>
kubectl get serviceaccount sre-<team>-deployer -n sre-<team>
```

### VLAN ID conflict

Before adding a new team, verify no ID is in use:

```bash
kubectl get network-attachment-definitions -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.config}{"\n"}{end}' | grep vlan
```

---

## 11. Capacity Planning

| Parameter | Per Team | Notes |
|-----------|----------|-------|
| VLANs | 4 | One per zone (public/private/system/data) |
| VyOS Router VM | 1 | 2 vCPU, 2Gi RAM, 5 NICs |
| Subnet size | /24 per zone | 254 usable IPs each |
| Max teams (VLAN IDs) | 10 per zone group | Using 10-step offsets (100,110,...,190) |
| Max teams (subnets) | 254 | 10.1-254.x.x range |

**To scale beyond 10 teams:** Use 5-step VLAN offsets (100,105,110...) to support up to 20 teams per zone group (max VLAN 4094 gives ~350+ teams if needed).

---

## 12. Security Notes

- VyOS router VMs are **not shared** between teams — each team owns their router
- Cluster network (`vpc-trunk`) and VLANConfig are shared infrastructure — only platform team modifies
- Team kubeconfigs are namespace-scoped — a team cannot see or touch another team's resources
- All inter-VLAN traffic is controlled by VyOS firewall zone policies — default deny
- Team VLANs are isolated at L2 by the physical switch trunk and Harvester VLAN tagging
- Do **not** share kubeconfig files between teams

---

## 13. Quick Reference — Team VLAN Calculator

Given team name and offset N:

```
public_vlan    = 100 + (N-1)*10      e.g. N=3 → 120
private_vlan   = 200 + (N-1)*10      e.g. N=3 → 220
system_vlan    = 300 + (N-1)*10      e.g. N=3 → 320
data_vlan      = 400 + (N-1)*10      e.g. N=3 → 420

public_cidr    = 10.N.0.0/24         e.g. N=3 → 10.3.0.0/24
private_cidr   = 10.N.1.0/24         e.g. N=3 → 10.3.1.0/24
system_cidr    = 10.N.2.0/24         e.g. N=3 → 10.3.2.0/24
data_cidr      = 10.N.3.0/24         e.g. N=3 → 10.3.3.0/24

vyos_mgmt_ip   = 192.168.1.N*10      e.g. N=3 → 192.168.1.30
namespace      = sre-<teamname>
```

---

## 14. Workload Stack Reference

This section describes how to deploy the standard three-tier workload stack inside your VPC.

### 14.1 RKE2 Kubernetes Cluster (PRIVATE VLAN)

**File:** `rke2_cluster.tf.example` → copy to `rke2_cluster.tf`

**How it works:**
- A `rancher2_cluster_v2` resource registers the cluster with Rancher
- Control-plane and worker VMs are provisioned in the PRIVATE VLAN (eth2 on VyOS)
- VyOS `WAN-TO-PRIV` rule allows Rancher to reach the K8s API on port 6443, restricted to `var.rancher_mgmt_cidr`
- Rancher provides kubeconfig, cluster health, and upgrade management

**Key variables:**
| Variable | Description | Example |
|----------|-------------|---------|
| `rancher_url` | Rancher management server URL | `https://rancher.example.com` |
| `rancher_access_key` | Rancher API access key | `token-xxxxx` |
| `rancher_secret_key` | Rancher API secret | (sensitive) |
| `rancher_mgmt_cidr` | CIDR allowed to reach port 6443 | `192.168.1.0/24` |

**Rancher → RKE2 traffic path:**
```
Rancher (mgmt net) → VyOS eth0 → WAN-TO-PRIV ruleset → VyOS eth2 → RKE2 node port 6443
```

### 14.2 PostgreSQL Primary-Standby HA (DATA VLAN)

**File:** `postgresql_ha.tf.example` → copy to `postgresql_ha.tf`

**How it works:**
- Two VMs are provisioned in the DATA VLAN (eth4 on VyOS)
- Primary is configured as a streaming replication source
- Standby runs `pg_basebackup` from primary on first boot, then stays in hot-standby mode
- **Replication traffic is intra-VLAN (L2) — it never crosses VyOS**, no extra firewall rule needed
- K8s apps in PRIVATE VLAN reach port 5432 via the existing `PRIV-TO-DATA` rule
- Vault in SYSTEM VLAN reaches port 5432 via the `SYS-TO-DATA` rule

**Failover:** PostgreSQL streaming replication does not provide automatic failover.
Use `pg_auto_failover` or `Patroni` on top of these VMs for production HA.

**Key variables:**
| Variable | Description | Default |
|----------|-------------|---------|
| `pg_version` | PostgreSQL major version | `"16"` |
| `pg_password` | Superuser password (sensitive) | — |
| `pg_replication_password` | Replication user password (sensitive) | — |

### 14.3 KV Store — Redis or Consul (SYSTEM VLAN)

**File:** `kv_store.tf.example` → copy to `kv_store.tf`

**How it works:**
- One VM is provisioned in the SYSTEM VLAN (eth3 on VyOS)
- VyOS `PRIV-TO-SYS rule 40` allows K8s pods to reach `var.kv_store_port`
- **Option A: Redis** (default, port 6379) — simple key-value / cache
- **Option B: Consul** (port 8500) — distributed KV + service mesh + health checks

**Switching between Redis and Consul:**
1. Set `kv_store_port = 8500` in `terraform.tfvars` for Consul
2. Comment out the Redis block in `kv_store.tf` and uncomment the Consul block
3. Run `terraform apply`

**Key variables:**
| Variable | Description | Default |
|----------|-------------|---------|
| `kv_store_port` | TCP port opened by VyOS firewall | `6379` (Redis) |

### 14.4 Deployment Order

Always deploy in this order to satisfy dependencies:

```
1. platform admin: cd infra/ && terraform apply        ← namespaces, RBAC, VLAN annotations
2. sre team:       cd my-team-vpc/ && terraform apply  ← VyOS router + 4 VLAN networks
3. sre team:       terraform apply (rke2_cluster.tf)   ← K8s cluster in PRIVATE VLAN
4. sre team:       terraform apply (postgresql_ha.tf)  ← PostgreSQL in DATA VLAN
5. sre team:       terraform apply (kv_store.tf)       ← KV store in SYSTEM VLAN
```

Steps 3-5 can be in the same `terraform.tf` workspace as step 2; they are separated into `.tf.example`
files only to keep the template modular. Copy whichever you need, rename, and apply together.
