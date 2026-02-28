# ══════════════════════════════════════════════════════════════
# VM Networks — One per VLAN zone
# ══════════════════════════════════════════════════════════════

resource "harvester_network" "vpc_vlans" {
  for_each = var.vlans

  name      = "vpc-${each.key}"
  namespace = var.namespace

  vlan_id              = each.value.vlan_id
  route_mode           = "manual"
  route_cidr           = each.value.cidr
  route_gateway        = each.value.gateway
  cluster_network_name = harvester_clusternetwork.vpc_trunk.name

  depends_on = [
    harvester_vlanconfig.vpc_trunk_nodes
  ]
}
