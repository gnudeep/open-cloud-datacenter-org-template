# ══════════════════════════════════════════════════════════════
# Platform Infrastructure — Run ONCE by platform/infra team
# Manages: ClusterNetwork, VLANConfig, Namespaces, RBAC
# ══════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 1.7"
    }
    rancher2 = {
      source  = "rancher/rancher2"
      version = "~> 13.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "harvester" {
  kubeconfig = var.harvester_kubeconfig
}

# Rancher2 connects to Harvester's embedded Rancher API.
# Harvester VIP serves the Rancher UI/API at https://<vip>/
provider "rancher2" {
  api_url    = var.rancher_url
  access_key = var.rancher_access_key
  secret_key = var.rancher_secret_key
  insecure   = var.rancher_insecure
}

provider "kubernetes" {
  config_path = var.harvester_kubeconfig
}

# ──────────────────────────────────────────────────────────────
# Shared Cluster Network (trunk — shared by ALL teams)
# ──────────────────────────────────────────────────────────────

resource "harvester_clusternetwork" "vpc_trunk" {
  name        = var.cluster_network_name
  description = "Shared VPC trunk — carries all team VLANs"
}

# One VLANConfig entry per Harvester node
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
