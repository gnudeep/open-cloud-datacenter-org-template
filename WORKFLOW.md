# Implementation Workflow — Multi-Team SRE VLAN Platform

> **Reference docs:** `AGENT.md` (architecture + allocation table) | `infra/` (platform Terraform) | `team-template/` (team Terraform)
> **Roles:** `[PLATFORM]` = Platform/Infra admin | `[SRE]` = SRE team member

---

## Overview

```
PHASE 0          PHASE 1            PHASE 1.5          PHASE 2              PHASE 3
Prerequisites → Platform Bootstrap → VLAN Governance → Team Onboarding  → Day-2 Operations
[PLATFORM]       [PLATFORM]          [PLATFORM]         [PLATFORM]+[SRE]    [SRE]
  │                  │                    │                    │                   │
  ▼                  ▼                    ▼                    ▼                   ▼
Tool setup      Switch + infra/     Kyverno install      VPC per team         Workloads,
VLAN planning   terraform apply     policy + audit       kubeconfig           changes, fixes
```

### VLAN Conflict Defence Model

```
Team creates harvester_network in terraform
         │
         ▼
[Layer 1] terraform plan
  variables.tf validation blocks
  Catches: wrong zone (e.g. private VLAN in 100-199 range)
  Does NOT catch: using another team's exact VLAN ID
         │ passes
         ▼
[Layer 2] Kubernetes API server + Kyverno admission webhook
  ClusterPolicy enforce-vlan-id-per-namespace
  Reads:   namespace annotation  platform/allowed-vlans
  Catches: ANY VLAN not in the team's exact allowed set
  Result:  REQUEST DENIED with clear error message
         │ passes (VLAN is in allowlist)
         ▼
[Layer 3] Periodic audit (scripts/audit-vlans.sh)
  Runs: manually, in CI, or as a CronJob
  Catches: any drift, orphaned resources, unannotated namespaces
  Result:  report + non-zero exit for alerting
         │
         ▼
       Network created
```

---

## Phase 0 — Prerequisites & Planning

**Role:** `[PLATFORM]`
**Do this:** Before any Terraform is run. Once per cluster lifetime.

### 0.1 Tool Versions

Verify on the machine that will run Terraform:

```bash
terraform version          # must be >= 1.5.0
kubectl version --client   # any recent version
```

### 0.2 Access

Confirm you have:

| Item | How to check |
|------|-------------|
| Harvester cluster admin kubeconfig | `kubectl --kubeconfig ~/.kube/harvester.yaml get nodes` |
| Harvester VIP (UI/API address) | Output of `kubectl get svc -n kube-system` or from cluster install |
| Physical switch CLI/SSH access | Manual verification |
| Terraform >= 1.5.0 | `terraform version` |

### 0.3 Plan Team VLAN Allocation

Before provisioning, decide how many teams and assign each a permanent **offset N** (1-based integer, never reuse).

Use the formula from `AGENT.md` Section 2:

```
Team Name   Offset  Public  Private  System  Data   Subnet Block     VyOS Mgmt IP
─────────────────────────────────────────────────────────────────────────────────
sre-alpha     1      100     200      300     400    10.1.0.0/22     192.168.1.10
sre-beta      2      110     210      310     410    10.2.0.0/22     192.168.1.20
sre-gamma     3      120     220      320     420    10.3.0.0/22     192.168.1.30
```

Write this table in a shared doc (e.g. Confluence, Notion). It is the **single source of truth** for allocations — never assign the same offset twice.

### 0.4 Checkpoint — Phase 0 Complete

```
[ ] Terraform >= 1.5.0 installed
[ ] Harvester admin kubeconfig accessible
[ ] Harvester VIP known
[ ] VLAN allocation table written and reviewed
[ ] Physical switch access confirmed
```

---

## Phase 1 — Platform Bootstrap

**Role:** `[PLATFORM]`
**Do this:** Once per cluster. Creates the shared trunk network, team namespaces, and RBAC.

### 1.1 Generate a Rancher API Key

The `infra/` module uses the Rancher2 provider to manage projects and namespaces.

1. Open Harvester UI: `https://<harvester-vip>/`
2. Click your avatar (top-right) → **API Keys**
3. Click **Add Key** → Description: `platform-infra-terraform` → No Expiry (or 1 year) → **Create**
4. Save the **Access Key** and **Secret Key** immediately — they are shown only once

### 1.2 Configure the Physical Switch

Add all team VLANs to the trunk ports **before** running Terraform.
Terraform creates the Harvester side; the switch must be ready first.

```
! Cisco IOS — add to your trunk interface
vlan 100,110,120,130,140
vlan 200,210,220,230,240
vlan 300,310,320,330,340
vlan 400,410,420,430,440

interface range GigabitEthernet0/1-3
 switchport trunk allowed vlan add 100,110,120,130,140,200,210,220,230,240,300,310,320,330,340,400,410,420,430,440
```

Verify the trunk is carrying the VLANs:

```
show interfaces trunk
show vlan brief
```

### 1.3 Fill infra/terraform.tfvars

```bash
cd infra/
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
harvester_kubeconfig = "~/.kube/harvester.yaml"
cluster_network_name = "vpc-trunk"

rancher_url        = "https://192.168.1.100"   # your Harvester VIP
rancher_access_key = "token-xxxxx"              # from step 1.1
rancher_secret_key = "xxxxxxxxxxxxxxxxxxxxxxxx" # from step 1.1
rancher_insecure   = true                       # true if self-signed cert
rancher_cluster_id = "local"

harvester_node_names = ["harvester-node-0", "harvester-node-1", "harvester-node-2"]
uplink_nics          = ["eth1"]                 # NIC on each node for the VLAN trunk
bond_mode            = "active-backup"

# Add only the teams you are onboarding NOW.
# You can add more teams later with another terraform apply.
sre_teams = {
  "sre-alpha" = { offset = 1 }
  "sre-beta"  = { offset = 2 }
}
```

> **Security:** Add `infra/terraform.tfvars` to `.gitignore`. It contains API credentials.
> Use a secrets manager or CI/CD vault injection in automated pipelines.

### 1.4 Initialize and Apply

```bash
terraform init

# Review what will be created
terraform plan -out=infra.tfplan

# Apply (takes ~2-5 minutes)
terraform apply infra.tfplan
```

Expected resources created per team:
- `rancher2_project.sre_teams["sre-alpha"]`
- `rancher2_namespace.sre_teams["sre-alpha"]`
- `kubernetes_service_account.sre_deployers["sre-alpha"]`
- `kubernetes_role_binding.sre_edit["sre-alpha"]`
- `kubernetes_role_binding.sre_harvester["sre-alpha"]`

Plus one-time shared resources:
- `harvester_clusternetwork.vpc_trunk`
- `harvester_vlanconfig.vpc_trunk_nodes["harvester-node-*"]` (one per node)
- `kubernetes_cluster_role.harvester_namespace_user`

### 1.5 Verify Platform Apply

```bash
# Cluster network exists
kubectl --kubeconfig ~/.kube/harvester.yaml get clusternetwork

# VLANConfig applied to all nodes
kubectl --kubeconfig ~/.kube/harvester.yaml get vlanconfig

# Namespaces created
kubectl --kubeconfig ~/.kube/harvester.yaml get namespace | grep sre-

# ServiceAccounts exist
kubectl --kubeconfig ~/.kube/harvester.yaml get serviceaccount -A | grep deployer
```

Check the Terraform output for the allocation summary:

```bash
terraform output team_allocations
terraform output namespaces_created
terraform output rancher_projects
```

### 1.6 Checkpoint — Phase 1 Complete

```
[ ] Switch trunk verified with all team VLANs
[ ] terraform apply completed with no errors
[ ] ClusterNetwork "vpc-trunk" visible in Harvester UI (Host → Network)
[ ] VLANConfig shown on all nodes
[ ] Namespaces visible in Harvester UI (Namespaces menu)
[ ] Rancher projects visible in Rancher UI (Cluster Management)
[ ] Namespace annotations set (verify: kubectl get namespace sre-alpha -o jsonpath='{.metadata.annotations}')
```

---

## Phase 1.5 — VLAN Governance Setup

**Role:** `[PLATFORM]`
**Do this:** After Phase 1 apply, before any SRE team is onboarded.
This is the enforcement layer that prevents L2 VLAN conflicts.

### 1.5.1 How the Three-Layer Defence Works

| Layer | Where | What it catches | Who sets it up |
|-------|-------|----------------|----------------|
| **Layer 1** | `terraform plan` (SRE side) | Wrong zone range (e.g. private VLAN in 100–199) | team-template/variables.tf validation |
| **Layer 2** | Kubernetes API server | Any VLAN not in team's exact allowlist | Kyverno ClusterPolicy |
| **Layer 3** | Scheduled audit script | Drift, orphans, unannotated namespaces | scripts/audit-vlans.sh |

The **namespace annotation** `platform/allowed-vlans` is the anchor — it is set by the platform team in `infra/` Terraform and SRE teams cannot modify it (no PATCH permission on Namespace objects).

### 1.5.2 Verify Namespace Annotations Were Set

After Phase 1 `terraform apply`, each namespace should have the annotation:

```bash
# Check one team
kubectl --kubeconfig ~/.kube/harvester.yaml \
  get namespace sre-alpha \
  -o jsonpath='{.metadata.annotations.platform/allowed-vlans}'
# Expected: 100,200,300,400

# Check all sre-* namespaces at once
kubectl --kubeconfig ~/.kube/harvester.yaml get namespace \
  -o jsonpath='{range .items[?(@.metadata.name matches "^sre-")]}{.metadata.name}{"\t"}{.metadata.annotations.platform/allowed-vlans}{"\n"}{end}'
```

### 1.5.3 Install Kyverno

Kyverno is the admission controller that enforces VLAN restrictions at the API server level. Install it once on the Harvester cluster:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=1 \
  --kubeconfig ~/.kube/harvester.yaml

# Wait for Kyverno to be ready (takes ~60 seconds)
kubectl --kubeconfig ~/.kube/harvester.yaml \
  wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=kyverno \
  -n kyverno \
  --timeout=120s
```

### 1.5.4 Deploy the VLAN Enforcement Policy

```bash
kubectl --kubeconfig ~/.kube/harvester.yaml \
  apply -f infra/kyverno/vlan-policy.yaml

# Verify policy is active
kubectl --kubeconfig ~/.kube/harvester.yaml \
  get clusterpolicy enforce-vlan-id-per-namespace
# Expected: READY=true, BACKGROUND=true, ACTION=enforce, FAILURE POLICY=Fail
```

### 1.5.5 Test the Policy (Dry-Run)

Before onboarding any team, confirm the policy blocks bad requests:

```bash
# This should be DENIED (VLAN 999 is not in any team's allowlist)
kubectl --kubeconfig ~/.kube/harvester.yaml apply --dry-run=server -f - <<'EOF'
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: test-bad-vlan
  namespace: sre-alpha
spec:
  config: '{"cniVersion":"0.3.1","name":"test","type":"bridge","vlan":999}'
EOF
# Expected: Error from server: admission webhook denied the request:
#           NETWORK CREATION DENIED — VLAN 999 is not allocated to namespace 'sre-alpha'.
#           Your allowed VLANs are: [100,200,300,400].

# This should be ALLOWED (VLAN 100 is in sre-alpha's allowlist)
kubectl --kubeconfig ~/.kube/harvester.yaml apply --dry-run=server -f - <<'EOF'
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: test-good-vlan
  namespace: sre-alpha
spec:
  config: '{"cniVersion":"0.3.1","name":"test","type":"bridge","vlan":100}'
EOF
# Expected: networkattachmentdefinition.k8s.cni.cncf.io/test-good-vlan configured (dry run)
```

### 1.5.6 Run the Baseline Audit

```bash
./scripts/audit-vlans.sh --kubeconfig ~/.kube/harvester.yaml
```

At this point (before any team VPCs are deployed) the output should show:
- No duplicate VLANs
- All sre-* namespaces annotated
- No out-of-allowlist VLANs (no networks exist yet)

### 1.5.7 Checkpoint — Phase 1.5 Complete

```
[ ] Namespace annotations verified for all sre-* namespaces
[ ] Kyverno installed and all pods Running
[ ] ClusterPolicy "enforce-vlan-id-per-namespace" is READY and ACTION=enforce
[ ] Policy dry-run test: bad VLAN denied, good VLAN allowed
[ ] Baseline audit script runs clean (exit code 0)
```

> **Note on rollout:** If you are adding Kyverno to an existing cluster that already has team VPCs deployed, first set `validationFailureAction: Audit` in `vlan-policy.yaml`, apply it, and run the audit script. Review all findings before switching to `Enforce`.

---

## Phase 2 — Team Onboarding

This phase has two parts: platform admin generates and delivers credentials, then the SRE team deploys their VPC.

### Part A — Platform Admin Actions

**Role:** `[PLATFORM]`

#### 2.A.1 Generate the Team's Scoped Kubeconfig

Run this script once per team. It creates a kubeconfig bound to the team's ServiceAccount and namespace.

```bash
#!/usr/bin/env bash
# Usage: ./gen-kubeconfig.sh sre-alpha
# Output: kubeconfig-sre-alpha.yaml

TEAM_NAME="${1:?Usage: $0 <team-name>}"
NAMESPACE="${TEAM_NAME}"
SA_NAME="${TEAM_NAME}-deployer"
KUBECONFIG_ADMIN="$HOME/.kube/harvester.yaml"
OUT_FILE="kubeconfig-${TEAM_NAME}.yaml"

echo "Generating kubeconfig for ${TEAM_NAME}..."

# Create a long-lived token for the ServiceAccount (Kubernetes 1.24+)
TOKEN=$(kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
  create token "${SA_NAME}" \
  --namespace "${NAMESPACE}" \
  --duration=8760h)

# Pull cluster connection info from admin kubeconfig
CLUSTER_SERVER=$(kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
  config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
  config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Write the scoped kubeconfig
cat > "${OUT_FILE}" <<EOF
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
    user: ${SA_NAME}
  name: ${TEAM_NAME}
current-context: ${TEAM_NAME}
users:
- name: ${SA_NAME}
  user:
    token: ${TOKEN}
EOF

echo "Written: ${OUT_FILE}"
echo "Verify access:"
echo "  kubectl --kubeconfig ${OUT_FILE} get pods -n ${NAMESPACE}"
```

Run it:

```bash
chmod +x gen-kubeconfig.sh

./gen-kubeconfig.sh sre-alpha   # → kubeconfig-sre-alpha.yaml
./gen-kubeconfig.sh sre-beta    # → kubeconfig-sre-beta.yaml
```

Verify each kubeconfig works before delivering:

```bash
kubectl --kubeconfig kubeconfig-sre-alpha.yaml get pods -n sre-alpha
# Expected: No resources found (namespace is empty — that's correct)

# Verify they CANNOT access other namespaces
kubectl --kubeconfig kubeconfig-sre-alpha.yaml get pods -n sre-beta
# Expected: Error from server (Forbidden)
```

#### 2.A.2 Prepare the Team Allocation Sheet

Create a short allocation document per team (copy this template):

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SRE Team VPC Allocation — sre-alpha
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Namespace:          sre-alpha
Cluster network:    vpc-trunk  (do not change)
Harvester nodes:    harvester-node-0, harvester-node-1, harvester-node-2
Uplink NIC:         eth1       (do not change)

VLAN Allocation:
  Public  (LBs):     VLAN 100  |  10.1.0.0/24  |  GW: 10.1.0.1
  Private (K8s):     VLAN 200  |  10.1.1.0/24  |  GW: 10.1.1.1
  System  (Vault):   VLAN 300  |  10.1.2.0/24  |  GW: 10.1.2.1
  Data    (DBs):     VLAN 400  |  10.1.3.0/24  |  GW: 10.1.3.1

VyOS Management IP:  192.168.1.10 (static on mgmt network)
Mgmt Gateway:        192.168.1.1

Kubeconfig file:     kubeconfig-sre-alpha.yaml  (attached)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 2.A.3 Deliver Credentials to the Team

Deliver via a **secure channel** (HashiCorp Vault, 1Password, GPG-encrypted email, or a secure file share):

- `kubeconfig-sre-alpha.yaml` — the scoped kubeconfig
- Allocation sheet above
- Link to this `WORKFLOW.md` and `AGENT.md`

**Never send kubeconfig files via Slack, plain email, or chat.**

#### Platform Admin Handoff Checkpoint

```
[ ] kubeconfig generated and verified (can access own namespace, blocked from others)
[ ] Allocation sheet prepared with correct VLAN IDs and subnets
[ ] Credentials delivered securely to team
[ ] Team contacts confirmed (Slack/email for questions)
```

---

### Part B — SRE Team Actions

**Role:** `[SRE]`

#### 2.B.1 Receive and Verify Your Kubeconfig

```bash
# Save your kubeconfig somewhere safe
mkdir -p ~/.kube
# Place kubeconfig-sre-<yourteam>.yaml here

# Verify it works
kubectl --kubeconfig ~/.kube/kubeconfig-sre-yourteam.yaml \
  get pods -n sre-yourteam
# Expected: No resources found in sre-yourteam namespace.
```

#### 2.B.2 Copy the Team Template

```bash
# From the repo root
cp -r team-template/ sre-yourteam-vpc/
cd sre-yourteam-vpc/
```

#### 2.B.3 Fill Your terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in every value from your allocation sheet.
Example for `sre-beta` (offset N=2):

```hcl
harvester_kubeconfig = "~/.kube/kubeconfig-sre-beta.yaml"
namespace            = "sre-beta"
cluster_network_name = "vpc-trunk"    # Do NOT change — platform-owned

harvester_node_names = ["harvester-node-0", "harvester-node-1", "harvester-node-2"]
uplink_nics          = ["eth1"]
bond_mode            = "active-backup"

vlans = {
  public = {
    vlan_id = 110           # 100 + (2-1)*10
    cidr    = "10.2.0.0/24"
    gateway = "10.2.0.1"
  }
  private = {
    vlan_id = 210           # 200 + (2-1)*10
    cidr    = "10.2.1.0/24"
    gateway = "10.2.1.1"
  }
  system = {
    vlan_id = 310           # 300 + (2-1)*10
    cidr    = "10.2.2.0/24"
    gateway = "10.2.2.1"
  }
  data = {
    vlan_id = 410           # 400 + (2-1)*10
    cidr    = "10.2.3.0/24"
    gateway = "10.2.3.1"
  }
}

mgmt_network_gateway = "192.168.1.1"
vyos_mgmt_ip         = "192.168.1.20"  # 192.168.1.(N*10)
vyos_mgmt_cidr       = "24"

vyos_cpu       = 2
vyos_memory    = "2Gi"
vyos_disk_size = "10Gi"

ssh_public_key = "ssh-ed25519 AAAA... your-team-public-key"
upstream_dns   = ["8.8.8.8", "1.1.1.1"]
```

> **Double-check:** VLAN IDs must exactly match your allocation sheet.
> Using the wrong VLAN ID will cause L2 mismatches that are hard to debug.

#### 2.B.4 Initialize and Apply

```bash
terraform init

# Review — read the plan carefully before applying
terraform plan -out=vpc.tfplan

# Apply (takes ~5-10 minutes — VyOS VM boots and runs cloud-init)
terraform apply vpc.tfplan
```

Expected resources created:
- `harvester_ssh_key.vpc_key`
- `harvester_image.vyos`
- `harvester_network.vpc_vlans["public"]`
- `harvester_network.vpc_vlans["private"]`
- `harvester_network.vpc_vlans["system"]`
- `harvester_network.vpc_vlans["data"]`
- `harvester_cloudinit_secret.vyos_config`
- `harvester_virtualmachine.vyos_router`

#### 2.B.5 Verify the VyOS Router

Wait 3-5 minutes after `apply` for VyOS cloud-init to complete, then:

```bash
# SSH to your VyOS router via its management IP
ssh vyos@192.168.1.<your-N-times-10>
# e.g. ssh vyos@192.168.1.20 for sre-beta
```

Run these checks inside VyOS:

```vyos
# All 5 interfaces must be shown (eth0=WAN + eth1-4=VLANs)
show interfaces

# Expected eth0 address = your vyos_mgmt_ip
# Expected eth1-4 addresses = your zone gateways

# Verify routing table has a default route
show ip route

# NAT rules (4 rules — one per VLAN zone)
show nat source rules

# Firewall zones (5 zones: WAN, public, private, system, data)
show firewall zone-policy

# DNS forwarding
show service dns forwarding
```

If VyOS is unreachable, see Troubleshooting in Phase 5.

#### 2.B.6 Verify Network Isolation

From a VM on your private VLAN, confirm:

```bash
# Can reach the internet (NAT working)
curl -s https://ifconfig.me

# Can reach system VLAN (Vault, registry)
ping 10.<N>.2.1

# CANNOT reach another team's subnet
ping 10.<other-team-N>.0.1   # should timeout
```

#### SRE Team Checkpoint — VPC Ready

```
[ ] terraform apply completed with no errors
[ ] VyOS SSH accessible on mgmt IP
[ ] All 5 VyOS interfaces show correct IPs
[ ] Default route present in VyOS routing table
[ ] NAT working (internet access from a test VM)
[ ] Cross-team ping blocked (isolation confirmed)
[ ] Notify platform admin: "VPC for sre-<name> is operational"
```

---

## Phase 3 — Day-2 Operations

### 3.1 Deploying Workload VMs

**Role:** `[SRE]`

Use `workload_vms.tf.example` as a starting point. Copy it to a real `.tf` file:

```bash
cp workload_vms.tf.example workload_vms.tf
# Edit workload_vms.tf for your actual VMs
terraform plan
terraform apply
```

Key rules for workload VMs:
- Always attach VMs to the correct VLAN network using `harvester_network.vpc_vlans["<zone>"].id`
- Put **ingress/LB VMs** on the `public` VLAN
- Put **RKE2 K8s cluster VMs** on the `private` VLAN → see Section 3.3
- Put **KV Store (Redis/Consul), Vault, registry** VMs on the `system` VLAN → see Section 3.5
- Put **PostgreSQL VMs** on the `data` VLAN → see Section 3.4

### 3.2 Modifying VyOS Firewall Rules

**Role:** `[SRE]`

VyOS firewall rules are generated by cloud-init and are baked into the VyOS configuration at boot. To make persistent changes:

**Option A — VyOS CLI (immediate, survives reboot if committed):**

```bash
ssh vyos@192.168.1.<your-ip>

# Enter config mode
configure

# Example: allow port 5432 from private to data
set firewall name PRIVATE-TO-DATA rule 50 action accept
set firewall name PRIVATE-TO-DATA rule 50 destination port 5432
set firewall name PRIVATE-TO-DATA rule 50 protocol tcp
set firewall name PRIVATE-TO-DATA rule 50 description 'PostgreSQL'

commit
save
exit
```

**Option B — Update cloud-init (recommended for reproducibility):**

Edit the VyOS configuration commands in `cloudinit.tf`, then:

```bash
terraform apply
# VyOS VM will restart with the new config (restart_after_update = true)
```

### 3.3 Deploying the RKE2 Kubernetes Cluster

**Role:** `[SRE]`

RKE2 cluster VMs live in the **PRIVATE VLAN**. Rancher manages the cluster lifecycle.

**Prerequisites:**
- `terraform.tfvars` has `rancher_url`, `rancher_access_key`, `rancher_secret_key`
- `rancher_mgmt_cidr` is set to the CIDR from which Rancher reaches port 6443
- VyOS is already deployed (Phase 2 Part B complete) — the `WAN-TO-PRIV` rule is already in place

```bash
# From your team Terraform workspace
cp rke2_cluster.tf.example rke2_cluster.tf
# Edit rke2_cluster.tf if you need to adjust CPU/memory/count

terraform plan   # verify new VMs and rancher2_cluster_v2 resource
terraform apply
```

After apply, the cluster appears in the Rancher UI under your project.
Download the kubeconfig from Rancher UI → Cluster → Download KubeConfig.

**Verify:**
```bash
# Using the kubeconfig downloaded from Rancher
kubectl --kubeconfig rancher-rke2.yaml get nodes
kubectl --kubeconfig rancher-rke2.yaml get pods -A
```

> See AGENT.md Section 14.1 for full traffic path details.

### 3.4 Deploying PostgreSQL Primary-Standby HA

**Role:** `[SRE]`

PostgreSQL VMs live in the **DATA VLAN**. Replication is intra-VLAN (L2) — it does not cross VyOS.

```bash
cp postgresql_ha.tf.example postgresql_ha.tf
# Set pg_version, pg_password, pg_replication_password in terraform.tfvars
# (never commit these — add to .gitignore)

terraform plan
terraform apply
```

After apply, note the primary IP from Terraform output:
```
pg_primary_ip = "10.N.3.x"
pg_standby_ip = "10.N.3.y"
```

**Verify replication:**
```bash
ssh ubuntu@10.N.3.x  # via VyOS jump host or bastion in private VLAN
sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"
```

**Connection string from K8s pods:**
```
postgresql://postgres:<password>@10.N.3.x:5432/mydb
```

> For automatic failover, overlay `Patroni` or `pg_auto_failover` on these VMs.
> See AGENT.md Section 14.2 for traffic matrix details.

### 3.5 Deploying the KV Store (Redis or Consul)

**Role:** `[SRE]`

The KV store VM lives in the **SYSTEM VLAN** alongside Vault and the container registry.

```bash
cp kv_store.tf.example kv_store.tf
# Default deploys Redis on port 6379
# For Consul: set kv_store_port = 8500 in terraform.tfvars
#   then swap Option A/B comments in kv_store.tf

terraform plan
terraform apply
```

After apply, note the KV IP from Terraform output:
```
redis_ip = "10.N.2.x"
```

**Verify from a K8s pod (PRIVATE VLAN):**
```bash
# Redis
redis-cli -h 10.N.2.x -p 6379 ping   # → PONG

# Consul
curl http://10.N.2.x:8500/v1/status/leader
```

**Kubernetes Secret for connection:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: redis-connection
stringData:
  REDIS_URL: "redis://10.N.2.x:6379"
```

> See AGENT.md Section 14.3 for Redis vs Consul guidance.

### 3.6 Enabling Internal DNS

**Role:** `[SRE]`

DNS is automatically enabled when you deploy the VyOS router — no extra steps needed for VM-level name resolution. This section explains what's configured and how to wire up K8s pods.

#### What you get automatically (after `terraform apply`)

VyOS dnsmasq serves your team's internal zone `var.dns_domain` (e.g., `sre-alpha.internal`):
- Every VLAN's DHCP tells VMs to use VyOS as their nameserver and `sre-alpha.internal` as their search domain
- VMs that set a hostname in cloud-init become resolvable within seconds of DHCP lease

```bash
# From any VM in any of your 4 VLANs — should work immediately
dig pg-primary.sre-alpha.internal
nslookup redis.sre-alpha.internal
```

**Important:** Your workload VMs must set a hostname in cloud-init:
```yaml
#cloud-config
hostname: pg-primary
fqdn: pg-primary.sre-alpha.internal
manage_etc_hosts: true
```

#### Wiring K8s pods to internal DNS (CoreDNS stub zone)

K8s pods use CoreDNS for DNS, not VyOS directly. Apply the stub zone so pods can resolve internal VM FQDNs:

```bash
cp coredns_stub_zone.tf.example coredns_stub_zone.tf
# Set rke2_kubeconfig_path in terraform.tfvars
terraform apply
```

Verify (CoreDNS hot-reloads within 30 seconds — no restart needed):
```bash
kubectl run dns-test --image=busybox:1.36 --restart=Never -it --rm -- \
  nslookup pg-primary.sre-alpha.internal
# Expected: Address: 10.N.3.x

# Your app deployments can now use FQDNs:
# postgresql://pg-primary.sre-alpha.internal:5432/mydb
# redis://redis.sre-alpha.internal:6379
# http://vault.sre-alpha.internal:8200
```

> See AGENT.md Section 15 for full DNS architecture and troubleshooting.

### 3.7 Adding a New Team (Platform Admin)

**Role:** `[PLATFORM]`

1. Assign the next offset N (check allocation table — no reuse)
2. Add VLANs to the physical switch (step 1.2 pattern)
3. Add the team to `infra/terraform.tfvars`:
   ```hcl
   sre_teams = {
     "sre-alpha"   = { offset = 1 }
     "sre-beta"    = { offset = 2 }
     "sre-gamma"   = { offset = 3 }  # ← new team
   }
   ```
4. Apply:
   ```bash
   cd infra/
   terraform apply
   ```
5. Generate kubeconfig and deliver (repeat Part A of Phase 2)

> `terraform apply` on `infra/` is **safe to run** any time — it only adds new resources for new teams. Existing team resources are untouched.

### 3.8 Rotating a Team's Kubeconfig

**Role:** `[PLATFORM]`

The kubeconfig token has a 1-year expiry by default. To rotate:

```bash
# Generate a fresh token — old tokens remain valid until their expiry
./gen-kubeconfig.sh sre-alpha

# Deliver the new kubeconfig-sre-alpha.yaml securely to the team
```

The team updates their local kubeconfig file — no Terraform changes needed.

### 3.9 Updating Team Resource Quotas

**Role:** `[PLATFORM]`

Edit the `resource_quota` blocks in `infra/rancher.tf` for the specific team, then:

```bash
cd infra/
terraform apply
```

### 3.10 Running the VLAN Conflict Audit

**Role:** `[PLATFORM]`

Run the audit script regularly (manually, in CI, or as a Kubernetes CronJob):

```bash
# Manual run
./scripts/audit-vlans.sh --kubeconfig ~/.kube/harvester.yaml

# Run after any team onboards or changes their VPC
# Exit code 0 = clean, exit code > 0 = conflicts found
```

**Automated — Kubernetes CronJob (run nightly):**

```yaml
# Apply with: kubectl apply -f - <<'EOF' ... EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vlan-audit
  namespace: kyverno
spec:
  schedule: "0 2 * * *"    # 02:00 UTC daily
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: kyverno
          restartPolicy: OnFailure
          containers:
          - name: audit
            image: bitnami/kubectl:latest
            command:
            - /bin/bash
            - /scripts/audit-vlans.sh
            volumeMounts:
            - name: audit-script
              mountPath: /scripts
          volumes:
          - name: audit-script
            configMap:
              name: vlan-audit-script
              defaultMode: 0755
```

**Alerting:** If the script returns non-zero, trigger a PagerDuty/Slack alert. The exit code equals the number of issues found.

---

## Phase 4 — Team Offboarding

When a team is being decommissioned, the cleanup happens in **two steps** with a specific order.

### 4.1 Team Destroys Their VPC

**Role:** `[SRE]` — team must do this first

```bash
cd sre-yourteam-vpc/
terraform destroy
```

Confirm all VMs, networks, images, and secrets are destroyed before notifying the platform team.

Verify nothing remains:

```bash
kubectl --kubeconfig ~/.kube/kubeconfig-sre-yourteam.yaml \
  get all -n sre-yourteam
# Expected: No resources found
```

### 4.2 Platform Admin Removes the Team

**Role:** `[PLATFORM]` — only after step 4.1 is confirmed

Remove the team from `infra/terraform.tfvars`:

```hcl
sre_teams = {
  "sre-alpha" = { offset = 1 }
  # "sre-beta" removed          ← comment out or delete
  "sre-gamma" = { offset = 3 }
}
```

Apply:

```bash
cd infra/
terraform plan   # confirm only sre-beta resources are being destroyed
terraform apply
```

> **Do NOT remove the team's offset number from your allocation table.** Mark it as retired instead. Never reassign a used offset — this prevents accidental VLAN ID reuse.

### 4.3 Update Allocation Table

Mark the offset as retired in your shared allocation doc:

```
sre-beta   | offset=2 | RETIRED 2026-03-15 | VLANs 110,210,310,410 freed
```

---

## Phase 5 — Troubleshooting Workflow

### 5.1 VyOS Not Reachable After Apply

```
Symptom: `ssh vyos@192.168.1.X` times out

Step 1 — Check VM is running in Harvester
  kubectl get vmi -n sre-<team>
  → If not Running: kubectl describe vmi vyos-vpc-router -n sre-<team>

Step 2 — Check cloud-init completed
  kubectl get pod -n sre-<team> | grep virt-launcher
  kubectl logs -n sre-<team> <virt-launcher-pod> -c compute | grep cloud-init

Step 3 — Check the VM got a DHCP lease on the mgmt network
  In Harvester UI: Virtual Machines → vyos-vpc-router → Network tab
  → eth0-wan should show an IP in 192.168.1.x range

Step 4 — VNC into the VM
  Harvester UI → Virtual Machine → Open Console
  Login: vyos / vyos (default before cloud-init applies SSH key)
  > show interfaces
  → If eth0 has no IP: cloud-init failed; check cloud-init output in console
```

### 5.2 VMs Not Getting DHCP from VyOS

```
Symptom: VM on VLAN has no IP

Step 1 — Check VM is on the correct VLAN network
  kubectl get vmi -n sre-<team> -o yaml | grep networkName

Step 2 — SSH to VyOS, check DHCP service
  show dhcp server leases
  show dhcp server statistics
  show configuration commands | grep dhcp

Step 3 — Check the VLAN network exists
  kubectl get net-attach-def -n sre-<team>

Step 4 — Check VLAN traffic is flowing (on Harvester host)
  bridge vlan show   # look for your VLAN ID on the bridge
  ip link show       # check bond and bridge interfaces
```

### 5.3 VLAN Traffic Not Passing Between Nodes

```
Symptom: VMs on same VLAN but on different nodes cannot reach each other

Step 1 — Verify switch trunk allows the VLAN
  On switch: show interfaces trunk
  VLAN must appear in "VLANs allowed and active in management domain"

Step 2 — Verify VLANConfig is applied to all nodes
  kubectl get vlanconfig -o yaml
  All nodes should have status.matchedNodes showing each hostname

Step 3 — Check physical bond on Harvester node
  ip link show bond0   # or your bond name
  ethtool bond0        # verify slave NICs

Step 4 — Contact platform team
  If VLANConfig looks correct, the switch trunk config needs review
```

### 5.4 Terraform Apply Fails — "namespace not found"

```
Symptom: SRE team runs terraform apply, gets "namespace sre-<team> not found"

Cause: Platform admin has not yet run infra/ terraform apply for this team

Fix (Platform admin):
  1. Add team to infra/terraform.tfvars
  2. cd infra/ && terraform apply
  3. Run gen-kubeconfig.sh again to get a fresh token
  4. Re-deliver kubeconfig to SRE team
```

### 5.5 Terraform Apply Fails — "VLAN ID already in use"

```
Symptom: harvester_network resource creation fails with VLAN conflict

Step 1 — Check all existing networks
  kubectl get net-attach-def -A -o jsonpath=\
    '{range .items[*]}{.metadata.namespace}{"\t"}{.spec.config}{"\n"}{end}' \
    | grep -o '"vlan":[0-9]*'

Step 2 — Compare against allocation table
  If a VLAN is in use by another team: update your vlans in terraform.tfvars
  Contact platform admin to revise the allocation

Step 3 — If VLAN is orphaned (team no longer exists):
  Platform admin removes the orphaned network manually:
  kubectl delete net-attach-def <name> -n <namespace>
```

---

## Quick-Reference Card

Cut out and pin this for daily use:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PLATFORM ADMIN — One-time bootstrap
  cd infra/
  cp terraform.tfvars.example terraform.tfvars  # fill it in
  terraform init && terraform plan && terraform apply

PLATFORM ADMIN — Add new team
  1. Add entry to infra/terraform.tfvars sre_teams map
  2. cd infra/ && terraform apply
  3. ./gen-kubeconfig.sh <team-name>
  4. Deliver kubeconfig + allocation sheet securely

SRE TEAM — Deploy your VPC
  cp -r team-template/ my-vpc/ && cd my-vpc/
  cp terraform.tfvars.example terraform.tfvars  # fill from allocation sheet
  terraform init && terraform plan && terraform apply
  ssh vyos@192.168.1.<your-ip>

SRE TEAM — Deploy workload VMs
  cp workload_vms.tf.example workload_vms.tf
  # edit then:
  terraform plan && terraform apply

SRE TEAM — Teardown
  terraform destroy   # then notify platform admin

PLATFORM ADMIN — Remove team
  # After team confirms destroy:
  # Remove from infra/terraform.tfvars, then:
  cd infra/ && terraform apply
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Contacts & Escalation

| Issue | Contact |
|-------|---------|
| Cannot access namespace / kubeconfig expired | Platform admin |
| Wrong VLAN allocation received | Platform admin |
| VyOS not responding, cloud-init failed | SRE team → escalate to Platform admin if unresolved in 1h |
| Physical switch / VLAN trunk issue | Platform admin → Network team |
| Harvester cluster node failure | Platform admin → Harvester cluster admin |
| New team onboarding request | Platform admin (allow 1 business day for provisioning) |
