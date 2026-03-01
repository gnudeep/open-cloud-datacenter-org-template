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
  description = "Your team's Harvester namespace (created by platform team, e.g. sre-alpha)"
  type        = string
  # No default — must be set in terraform.tfvars
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
  description = "VLAN network definitions for VPC zones. IDs must match your allocation in AGENT.md."
  type = map(object({
    vlan_id = number
    cidr    = string
    gateway = string
  }))

  # ── Zone range validation ──
  # Each zone has a reserved VLAN ID range. Putting the wrong VLAN in the
  # wrong zone causes routing mismatches on the VyOS router.
  # Cross-team conflicts (using another team's exact VLAN) are caught by
  # the Kyverno admission policy at the Kubernetes API level.
  validation {
    condition = (
      var.vlans["public"].vlan_id >= 100 && var.vlans["public"].vlan_id <= 199
    )
    error_message = "public VLAN ID must be in range 100-199. Check your allocation in AGENT.md."
  }

  validation {
    condition = (
      var.vlans["private"].vlan_id >= 200 && var.vlans["private"].vlan_id <= 299
    )
    error_message = "private VLAN ID must be in range 200-299. Check your allocation in AGENT.md."
  }

  validation {
    condition = (
      var.vlans["system"].vlan_id >= 300 && var.vlans["system"].vlan_id <= 399
    )
    error_message = "system VLAN ID must be in range 300-399. Check your allocation in AGENT.md."
  }

  validation {
    condition = (
      var.vlans["data"].vlan_id >= 400 && var.vlans["data"].vlan_id <= 499
    )
    error_message = "data VLAN ID must be in range 400-499. Check your allocation in AGENT.md."
  }

  # ── Subnet validity: no two zones should share the same CIDR ──
  validation {
    condition = length(distinct([
      var.vlans["public"].cidr,
      var.vlans["private"].cidr,
      var.vlans["system"].cidr,
      var.vlans["data"].cidr,
    ])) == 4
    error_message = "Each VLAN zone must have a unique CIDR. Check your terraform.tfvars."
  }

  # ── All four required zones must be present ──
  validation {
    condition = (
      contains(keys(var.vlans), "public") &&
      contains(keys(var.vlans), "private") &&
      contains(keys(var.vlans), "system") &&
      contains(keys(var.vlans), "data")
    )
    error_message = "vlans map must contain exactly four keys: public, private, system, data."
  }

  # Defaults are for sre-alpha (team offset N=1).
  # Each SRE team MUST override in terraform.tfvars.
  # See AGENT.md Section 2 for the VLAN formula and allocation table.
  default = {
    public = {
      vlan_id = 100 # N=1: 100+(N-1)*10
      cidr    = "10.1.0.0/24"
      gateway = "10.1.0.1"
    }
    private = {
      vlan_id = 200 # N=1: 200+(N-1)*10
      cidr    = "10.1.1.0/24"
      gateway = "10.1.1.1"
    }
    system = {
      vlan_id = 300 # N=1: 300+(N-1)*10
      cidr    = "10.1.2.0/24"
      gateway = "10.1.2.1"
    }
    data = {
      vlan_id = 400 # N=1: 400+(N-1)*10
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

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.[a-z]{2,}$", var.dns_domain))
    error_message = "dns_domain must be a simple two-label domain like sre-alpha.internal."
  }
}

variable "extra_service_dns" {
  description = <<-EOT
    Additional VyOS static-host-mapping entries for application-specific service names.
    Key   = short hostname (e.g. "choreo", "vault", "registry")
    Value = static IP in any of the four VLANs

    The full FQDN will be <key>.<dns_domain>  (e.g. choreo.sre-alpha.internal)
    IPs should be in the reserved range (.10-.99) of the relevant VLAN subnet.

    Example for OpenChoreo:
      extra_service_dns = {
        "choreo"        = "10.1.0.10"   # Nginx LB in PUBLIC VLAN
        "choreo-api"    = "10.1.0.10"   # Same LB, separate DNS name
        "choreo-id"     = "10.1.0.10"   # Thunder IdP via same LB
      }
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

variable "redis_password" {
  description = "Redis requirepass authentication password. Must be a strong secret — never leave empty."
  type        = string
  sensitive   = true
}

# ── Rancher2 Provider (for RKE2 cluster provisioning) ──
variable "rancher_url" {
  description = "Rancher management server URL (e.g. https://rancher.example.com)"
  type        = string
}

variable "rancher_access_key" {
  description = "Rancher API access key"
  type        = string
  sensitive   = true
}

variable "rancher_secret_key" {
  description = "Rancher API secret key"
  type        = string
  sensitive   = true
}

variable "rancher_insecure" {
  description = "Skip TLS verification for Rancher API (dev/lab only)"
  type        = bool
  default     = false
}
