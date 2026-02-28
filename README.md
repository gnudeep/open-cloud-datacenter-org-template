# Harvester VPC-like Network with VyOS Router

Terraform configuration to create a VPC-like network isolation on Harvester HCI 1.7.1 using VLANs and a VyOS router VM.

## Architecture

```
Internet → Basic FW (192.168.1.1) → VyOS Router VM → 4 VLAN Zones
                                         │
                    ┌────────────┬────────┼────────┬────────────┐
                    │            │        │        │            │
              VLAN 100     VLAN 200   VLAN 300   VLAN 400
              Public       Private    System     Data
              (LBs)        (K8s)     (Vault/Reg) (DBs)
```

## Traffic Matrix

| Source → Dest    | Public | Private | System | Data |
|------------------|--------|---------|--------|------|
| **WAN**          | ✅ 80,443 | ❌   | ❌     | ❌   |
| **Public**       | —      | ✅ NodePort | ❌  | ❌   |
| **Private**      | ❌     | —       | ✅ Vault,Reg | ✅ PG,Redis,Kafka |
| **System**       | ❌     | ❌      | —      | ✅ PG |
| **Data**         | ❌     | ❌      | ❌     | —    |

## Prerequisites

- Harvester HCI 1.7.1 cluster (3+ nodes)
- Physical switch with VLAN trunk configured (VLANs 100, 200, 300, 400)
- Basic firewall/gateway providing internet access
- Terraform >= 1.0

## Quick Start

```bash
# 1. Clone and configure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# 2. Initialize
terraform init

# 3. Review
terraform plan

# 4. Deploy
terraform apply
```

## Files

| File | Description |
|------|-------------|
| `provider.tf` | Harvester provider configuration |
| `variables.tf` | All configurable variables |
| `cluster_network.tf` | Cluster network + per-node VLAN config |
| `networks.tf` | VM networks (one per VLAN zone) |
| `images.tf` | VyOS image + SSH key |
| `cloudinit.tf` | VyOS cloud-init with full firewall config |
| `vyos_router.tf` | VyOS router VM (5 NICs) |
| `outputs.tf` | Useful output values |
| `workload_vms.tf.example` | Example VMs for each VLAN zone |

## What You Need to Customize

1. **`harvester_node_names`** — your actual Harvester node hostnames
2. **`uplink_nics`** — the physical NIC(s) carrying VLAN trunk traffic
3. **`mgmt_network_gateway`** — your basic firewall/gateway IP
4. **`vyos_mgmt_ip`** — static IP for VyOS on your management network
5. **`ssh_public_key`** — your SSH public key
6. **`vyos_image_url`** — verify the VyOS image URL is current

## Post-Deployment

### Verify VyOS

```bash
ssh vyos@192.168.1.10

# Check interfaces
show interfaces

# Check routing
show ip route

# Check firewall zones
show firewall zone-policy

# Check NAT
show nat source rules

# Check DHCP leases
show dhcp server leases
```

### Deploy Workload VMs

See `workload_vms.tf.example` for examples of creating VMs on each VLAN.
The key is setting the correct `network_name` in each VM's `network_interface`:

```hcl
network_interface {
  name         = "nic-private"
  model        = "virtio"
  type         = "bridge"
  network_name = harvester_network.vpc_vlans["private"].id
}
```

### Switch Configuration (Cisco 2960-S)

```
vlan 100
 name Public-LB
vlan 200
 name Private-K8s
vlan 300
 name System-Vault-Reg
vlan 400
 name Data-DB

interface range GigabitEthernet0/1-3
 switchport mode trunk
 switchport trunk allowed vlan 100,200,300,400
 spanning-tree portfast trunk
```

## Scaling to Multi-Tenant (VRF)

To add per-tenant isolation with overlapping subnets, you would:
1. Add more VLANs per tenant (3 per tenant: private, system, data)
2. Configure VRF on VyOS for each tenant
3. Use sub-interfaces instead of dedicated NICs

See the VRF diagram for the full architecture.
