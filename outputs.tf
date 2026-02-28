# ══════════════════════════════════════════════════════════════
# Outputs
# ══════════════════════════════════════════════════════════════

output "cluster_network" {
  description = "VPC cluster network name"
  value       = harvester_clusternetwork.vpc_trunk.name
}

output "vlan_networks" {
  description = "Created VLAN network details"
  value = {
    for k, v in harvester_network.vpc_vlans : k => {
      id      = v.id
      name    = v.name
      vlan_id = v.vlan_id
    }
  }
}

output "vyos_router_id" {
  description = "VyOS router VM ID"
  value       = harvester_virtualmachine.vyos_router.id
}

output "vyos_mgmt_ip" {
  description = "VyOS management IP (SSH access)"
  value       = var.vyos_mgmt_ip
}

output "vpc_summary" {
  description = "VPC network summary"
  value = {
    for k, v in var.vlans : k => {
      vlan_id = v.vlan_id
      cidr    = v.cidr
      gateway = v.gateway
    }
  }
}

output "network_ids_for_vms" {
  description = "Use these network IDs when creating VMs on each VLAN"
  value = {
    for k, v in harvester_network.vpc_vlans : k => v.id
  }
}
