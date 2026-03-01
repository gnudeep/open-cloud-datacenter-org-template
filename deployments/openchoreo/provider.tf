# ══════════════════════════════════════════════════════════════
# OpenChoreo Deployment — Provider Configuration
#
# This is a SEPARATE Terraform workspace from your team VPC.
# Apply the team VPC first (rke2_cluster.tf + postgresql_ha.tf),
# then apply this workspace.
#
# Providers:
#   harvester  — creates the Nginx proxy VM in PUBLIC VLAN
#   helm       — installs cert-manager, Thunder, OpenChoreo via Helm
#   kubernetes — manages K8s secrets, services, CoreDNS config
#   null       — applies Gateway API CRDs via kubectl local-exec
# ══════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 1.7"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ── Harvester provider ──
# Used for the Nginx LB proxy VM in PUBLIC VLAN.
provider "harvester" {
  kubeconfig = var.harvester_kubeconfig
}

# ── Helm provider — targets the RKE2 cluster ──
provider "helm" {
  kubernetes {
    config_path = var.rke2_kubeconfig_path
  }
}

# ── Kubernetes provider — targets the RKE2 cluster ──
provider "kubernetes" {
  config_path = var.rke2_kubeconfig_path
}
