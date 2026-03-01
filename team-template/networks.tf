# ══════════════════════════════════════════════════════════════
# VM Networks — One per VLAN zone
# ══════════════════════════════════════════════════════════════

resource "harvester_network" "vpc_vlans" {
  for_each = var.vlans

  name      = "vpc-${each.key}"
  namespace = var.namespace

  vlan_id       = each.value.vlan_id
  route_mode    = "manual"
  route_cidr    = each.value.cidr
  route_gateway = each.value.gateway
  # Reference the shared cluster network by name (created by platform team via infra/)
  cluster_network_name = var.cluster_network_name
}
