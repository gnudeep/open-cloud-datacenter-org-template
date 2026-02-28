# ══════════════════════════════════════════════════════════════
# Platform Outputs
# ══════════════════════════════════════════════════════════════

output "cluster_network" {
  description = "Shared cluster network name (give to all SRE teams)"
  value       = harvester_clusternetwork.vpc_trunk.name
}

output "team_allocations" {
  description = "VLAN and subnet allocation per team — share with each team"
  value = {
    for team, cfg in var.sre_teams : team => {
      namespace    = team
      vlan_public  = 100 + (cfg.offset - 1) * 10
      vlan_private = 200 + (cfg.offset - 1) * 10
      vlan_system  = 300 + (cfg.offset - 1) * 10
      vlan_data    = 400 + (cfg.offset - 1) * 10
      subnet_block = "10.${cfg.offset}.0.0/22"
      public_cidr  = "10.${cfg.offset}.0.0/24"
      private_cidr = "10.${cfg.offset}.1.0/24"
      system_cidr  = "10.${cfg.offset}.2.0/24"
      data_cidr    = "10.${cfg.offset}.3.0/24"
      vyos_mgmt_ip = "192.168.1.${cfg.offset * 10}"
      sa_name      = "${team}-deployer"
    }
  }
}

output "namespaces_created" {
  description = "List of team namespaces created"
  value       = [for ns in rancher2_namespace.sre_teams : ns.name]
}

output "rancher_projects" {
  description = "Rancher project IDs per team"
  value       = { for k, p in rancher2_project.sre_teams : k => p.id }
}
