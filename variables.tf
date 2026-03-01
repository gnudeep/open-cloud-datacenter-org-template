# ══════════════════════════════════════════════════════════════
# Harvester VPC-like Network with VyOS Router
# Variables
# ══════════════════════════════════════════════════════════════

# ── Provider ──
variable "harvester_kubeconfig" {
  description = "Path to Harvester kubeconfig file"
  type        = string
  default     = "~/.kube/harvester.yaml"
}

# ── Namespace ──
variable "namespace" {
  description = "Harvester namespace for all resources"
  type        = string
  default     = "harvester-public"
}

# ── Cluster Network ──
variable "cluster_network_name" {
  description = "Name of the Harvester cluster network for VLAN traffic"
  type        = string
  default     = "vpc-trunk"
}

variable "uplink_nics" {
  description = "Physical NICs on each Harvester node for VLAN trunk"
  type        = list(string)
  default     = ["eth1"]
}

variable "bond_mode" {
  description = "Bond mode for uplink NICs (active-backup, balance-slb, etc.)"
  type        = string
  default     = "active-backup"
}

variable "harvester_node_names" {
  description = "List of Harvester node hostnames for VLAN config"
  type        = list(string)
  default     = ["harvester-node-0", "harvester-node-1", "harvester-node-2"]
}

# ── VLAN Definitions ──
variable "vlans" {
  description = "VLAN network definitions for VPC zones"
  type = map(object({
    vlan_id = number
    cidr    = string
    gateway = string
  }))
  # Defaults are for sre-alpha (team N=1): 10.1.0.0/22 block
  # Formula: public=10.N.0.0/24, private=10.N.1.0/24, system=10.N.2.0/24, data=10.N.3.0/24
  default = {
    public = {
      vlan_id = 100
      cidr    = "10.1.0.0/24"
      gateway = "10.1.0.1"
    }
    private = {
      vlan_id = 200
      cidr    = "10.1.1.0/24"
      gateway = "10.1.1.1"
    }
    system = {
      vlan_id = 300
      cidr    = "10.1.2.0/24"
      gateway = "10.1.2.1"
    }
    data = {
      vlan_id = 400
      cidr    = "10.1.3.0/24"
      gateway = "10.1.3.1"
    }
  }
}

# ── Management Network ──
variable "mgmt_network_gateway" {
  description = "Gateway IP of existing management network (basic FW)"
  type        = string
  default     = "192.168.1.1"
}

variable "vyos_mgmt_ip" {
  description = "Static IP for VyOS on management network"
  type        = string
  default     = "192.168.1.10"
}

variable "vyos_mgmt_cidr" {
  description = "CIDR prefix for management network"
  type        = string
  default     = "24"
}

# ── VyOS Router VM ──
variable "vyos_image_url" {
  description = "URL to VyOS cloud-init image (qcow2)"
  type        = string
  default     = "https://github.com/vyos/vyos-rolling-nightly-builds/releases/download/1.5-rolling-202402120023/vyos-1.5-rolling-202402120023-cloud-init-10G-qemu.qcow2"
}

variable "vyos_cpu" {
  description = "Number of vCPUs for VyOS router VM"
  type        = number
  default     = 2
}

variable "vyos_memory" {
  description = "Memory for VyOS router VM"
  type        = string
  default     = "2Gi"
}

variable "vyos_disk_size" {
  description = "Root disk size for VyOS router VM"
  type        = string
  default     = "10Gi"
}

# ── SSH ──
variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

# ── DNS ──
variable "upstream_dns" {
  description = "Upstream DNS servers for VyOS forwarding"
  type        = list(string)
  default     = ["8.8.8.8", "1.1.1.1"]
}

variable "dns_domain" {
  description = "Internal DNS domain for this team's VPC (e.g. sre-alpha.internal). VyOS serves this zone authoritatively; VMs become resolvable as hostname.dns_domain via DHCP lease registration."
  type        = string
  default     = "sre-alpha.internal"

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.[a-z]{2,}$", var.dns_domain))
    error_message = "dns_domain must be a simple two-label domain like sre-alpha.internal."
  }
}

variable "extra_service_dns" {
  description = <<-EOT
    Additional VyOS static-host-mapping entries for application-specific service names.
    Key   = short hostname (e.g. "choreo", "vault")
    Value = static IP in any VLAN (.10-.99 reserved range)
    Full FQDN = <key>.<dns_domain>
  EOT
  type        = map(string)
  default     = {}
}

# ── Workload Stack ──
variable "rancher_mgmt_cidr" {
  description = "CIDR of the Rancher management network; VyOS allows port 6443 from here into the PRIVATE VLAN"
  type        = string
  default     = "192.168.1.0/24"
}

variable "kv_store_port" {
  description = "TCP port for the KV store in the SYSTEM VLAN (6379 = Redis, 8500 = Consul)"
  type        = number
  default     = 6379
}
