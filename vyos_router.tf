# ══════════════════════════════════════════════════════════════
# VyOS Router VM — Core of the VPC network
# 5 NICs: 1 WAN (mgmt) + 4 VLAN zones
# ══════════════════════════════════════════════════════════════

resource "harvester_virtualmachine" "vyos_router" {
  name                 = "vyos-vpc-router"
  namespace            = var.namespace
  description          = "VyOS router VM for VPC-like VLAN isolation"
  restart_after_update = true

  cpu          = var.vyos_cpu
  memory       = var.vyos_memory
  run_strategy = "RerunOnFailure"
  hostname     = "vyos-vpc-router"
  machine_type = "q35"

  ssh_keys = [
    harvester_ssh_key.vpc_key.id
  ]

  tags = {
    role     = "router"
    ssh-user = "vyos"
  }

  # ── NIC 0: Management / WAN ──
  # Connected to existing mgmt network (has internet via basic FW)
  network_interface {
    name           = "eth0-wan"
    wait_for_lease = true
  }

  # ── NIC 1: Public VLAN (LBs) ──
  network_interface {
    name         = "eth1-public"
    model        = "virtio"
    type         = "bridge"
    network_name = harvester_network.vpc_vlans["public"].id
  }

  # ── NIC 2: Private VLAN (K8s) ──
  network_interface {
    name         = "eth2-private"
    model        = "virtio"
    type         = "bridge"
    network_name = harvester_network.vpc_vlans["private"].id
  }

  # ── NIC 3: System VLAN (Vault, Registry) ──
  network_interface {
    name         = "eth3-system"
    model        = "virtio"
    type         = "bridge"
    network_name = harvester_network.vpc_vlans["system"].id
  }

  # ── NIC 4: Data VLAN (Databases) ──
  network_interface {
    name         = "eth4-data"
    model        = "virtio"
    type         = "bridge"
    network_name = harvester_network.vpc_vlans["data"].id
  }

  # ── Root Disk ──
  disk {
    name       = "rootdisk"
    type       = "disk"
    size       = var.vyos_disk_size
    bus        = "virtio"
    boot_order = 1
    image      = harvester_image.vyos.id
    auto_delete = true
  }

  # ── Cloud-Init ──
  cloudinit {
    user_data_secret_name    = harvester_cloudinit_secret.vyos_config.name
    network_data_secret_name = harvester_cloudinit_secret.vyos_config.name
  }

  depends_on = [
    harvester_network.vpc_vlans,
    harvester_image.vyos
  ]
}
