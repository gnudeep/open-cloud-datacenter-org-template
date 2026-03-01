# ══════════════════════════════════════════════════════════════
# OpenChoreo Deployment — Data Sources
#
# These look up resources created by the team VPC workspace.
# The team VPC must be applied BEFORE this workspace.
# ══════════════════════════════════════════════════════════════

# ── PUBLIC VLAN network (created by team-template/networks.tf) ──
# Name format: "vpc-<zone>" as defined in team-template/networks.tf:
#   name = "vpc-${each.key}"
data "harvester_network" "public" {
  name      = "vpc-public"
  namespace = var.namespace
}

# ── Ubuntu image (must be uploaded to the team namespace) ──
# Upload once: Harvester UI → Images → Upload → Ubuntu 22.04 cloud image
# Set ubuntu_image_name in terraform.tfvars to match the display name used.
data "harvester_image" "ubuntu" {
  display_name = var.ubuntu_image_name
  namespace    = var.namespace
}
