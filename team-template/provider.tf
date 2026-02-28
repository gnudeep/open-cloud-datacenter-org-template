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
  }
}

provider "harvester" {
  kubeconfig = var.harvester_kubeconfig
}

provider "rancher2" {
  api_url    = var.rancher_url
  access_key = var.rancher_access_key
  secret_key = var.rancher_secret_key
  insecure   = var.rancher_insecure
}
