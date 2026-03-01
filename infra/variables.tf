# ══════════════════════════════════════════════════════════════
# Platform Infrastructure Variables
# ══════════════════════════════════════════════════════════════

variable "harvester_kubeconfig" {
  description = "Path to Harvester admin kubeconfig"
  type        = string
  default     = "~/.kube/harvester.yaml"
}

variable "cluster_network_name" {
  description = "Name of the shared VLAN trunk cluster network"
  type        = string
  default     = "vpc-trunk"
}

variable "harvester_node_names" {
  description = "List of all Harvester node hostnames"
  type        = list(string)
  default     = ["harvester-node-0", "harvester-node-1", "harvester-node-2"]
}

variable "uplink_nics" {
  description = "Physical NIC(s) on each node for the VLAN trunk"
  type        = list(string)
  default     = ["eth1"]
}

variable "bond_mode" {
  description = "Bond mode for uplink NICs"
  type        = string
  default     = "active-backup"
}

# ── Rancher2 Connection ──
# Harvester embeds Rancher; the API is at https://<harvester-vip>/
# Generate an API key in Rancher UI: User Menu → API Keys → Add Key
variable "rancher_url" {
  description = "Rancher API URL (e.g. https://192.168.1.100 for Harvester's embedded Rancher)"
  type        = string
}

variable "rancher_access_key" {
  description = "Rancher API access key (token-xxxxx)"
  type        = string
  sensitive   = true
}

variable "rancher_secret_key" {
  description = "Rancher API secret key"
  type        = string
  sensitive   = true
}

variable "rancher_insecure" {
  description = "Skip TLS verification (set true for self-signed certs on Harvester)"
  type        = bool
  default     = false
}

variable "rancher_cluster_id" {
  description = "Harvester cluster ID as seen by Rancher (e.g. local or c-xxxxx)"
  type        = string
  default     = "local"
}

variable "sre_teams" {
  description = <<-EOT
    Map of SRE team names to their configuration.
    Key: namespace name (e.g. "sre-alpha")
    offset: team number 1..N — drives VLAN IDs and subnet addressing.

    VLAN formula:  public=100+(offset-1)*10, private=200+(offset-1)*10,
                   system=300+(offset-1)*10, data=400+(offset-1)*10
    Subnet block:  10.<offset>.0.0/22
    VyOS mgmt IP:  192.168.1.<offset*10>
  EOT
  type = map(object({
    offset = number # 1-based team index
  }))
  default = {
    "sre-alpha" = { offset = 1 }
    "sre-beta"  = { offset = 2 }
  }
}
