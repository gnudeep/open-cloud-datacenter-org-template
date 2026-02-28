# ══════════════════════════════════════════════════════════════
# Cluster Network & VLAN Configuration
# ══════════════════════════════════════════════════════════════

# ── Reference the built-in management cluster network ──
data "harvester_clusternetwork" "mgmt" {
  name = "mgmt"
}

# ── Create a dedicated cluster network for VPC VLAN traffic ──
resource "harvester_clusternetwork" "vpc_trunk" {
  name        = var.cluster_network_name
  description = "VPC trunk network for VLAN-based isolation"
}

# ── VLAN Config per Harvester node ──
# Maps the physical NICs on each node to the cluster network
resource "harvester_vlanconfig" "vpc_trunk_nodes" {
  for_each = toset(var.harvester_node_names)

  name                 = "${var.cluster_network_name}-${each.key}"
  cluster_network_name = harvester_clusternetwork.vpc_trunk.name

  uplink {
    nics      = var.uplink_nics
    bond_mode = var.bond_mode
    mtu       = 1500
  }

  node_selector = {
    "kubernetes.io/hostname" = each.key
  }
}
