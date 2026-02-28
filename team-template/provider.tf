terraform {
  required_version = ">= 1.5.0"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 1.7"
    }
  }
}

provider "harvester" {
  kubeconfig = var.harvester_kubeconfig
}
