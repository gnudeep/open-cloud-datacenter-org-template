# ══════════════════════════════════════════════════════════════
# VyOS Cloud-Init Configuration
# ══════════════════════════════════════════════════════════════

locals {
  # Build VLAN interface configs for cloud-init
  vlan_interfaces = {
    for k, v in var.vlans : k => {
      gateway = v.gateway
      cidr    = v.cidr
    }
  }

  # VyOS cloud-init user-data
  vyos_userdata = <<-USERDATA
    #cloud-config
    vyos_config_commands:
      # ── Interfaces ──
      - set interfaces ethernet eth0 address '${var.vyos_mgmt_ip}/${var.vyos_mgmt_cidr}'
      - set interfaces ethernet eth0 description 'WAN - Management'
      - set interfaces ethernet eth1 address '${var.vlans.public.gateway}/${split("/", var.vlans.public.cidr)[1]}'
      - set interfaces ethernet eth1 description 'Public - Load Balancers'
      - set interfaces ethernet eth2 address '${var.vlans.private.gateway}/${split("/", var.vlans.private.cidr)[1]}'
      - set interfaces ethernet eth2 description 'Private - Kubernetes'
      - set interfaces ethernet eth3 address '${var.vlans.system.gateway}/${split("/", var.vlans.system.cidr)[1]}'
      - set interfaces ethernet eth3 description 'System - KV Store, Vault, Registry'
      - set interfaces ethernet eth4 address '${var.vlans.data.gateway}/${split("/", var.vlans.data.cidr)[1]}'
      - set interfaces ethernet eth4 description 'Data - PostgreSQL Primary-Standby'

      # ── Default route to internet ──
      - set protocols static route 0.0.0.0/0 next-hop '${var.mgmt_network_gateway}'

      # ── System settings ──
      - set system host-name 'vyos-vpc-router'
      - set system name-server '${var.upstream_dns[0]}'

      # ── Service DNS — stable FQDNs for well-known infrastructure VMs ──
      # IPs are in the reserved range (.10-.99); DHCP pool starts at .100.
      # These records exist from day 1 — before the VMs are even deployed.
      # When VMs are provisioned with matching static IPs, they resolve immediately.
      - set system static-host-mapping host-name 'postgres.${var.dns_domain}' inet '${cidrhost(var.vlans.data.cidr, 10)}'
      - set system static-host-mapping host-name 'postgres-ro.${var.dns_domain}' inet '${cidrhost(var.vlans.data.cidr, 11)}'
      - set system static-host-mapping host-name 'redis.${var.dns_domain}' inet '${cidrhost(var.vlans.system.cidr, 10)}'

      # ══════════════════════════════════════
      # NAT — All VLANs masquerade to WAN
      # ══════════════════════════════════════
      - set nat source rule 10 outbound-interface name 'eth0'
      - set nat source rule 10 source address '${var.vlans.public.cidr}'
      - set nat source rule 10 translation address 'masquerade'
      - set nat source rule 20 outbound-interface name 'eth0'
      - set nat source rule 20 source address '${var.vlans.private.cidr}'
      - set nat source rule 20 translation address 'masquerade'
      - set nat source rule 30 outbound-interface name 'eth0'
      - set nat source rule 30 source address '${var.vlans.system.cidr}'
      - set nat source rule 30 translation address 'masquerade'
      - set nat source rule 40 outbound-interface name 'eth0'
      - set nat source rule 40 source address '${var.vlans.data.cidr}'
      - set nat source rule 40 translation address 'masquerade'

      # ══════════════════════════════════════
      # DNS Forwarding
      # ══════════════════════════════════════
      - set service dns forwarding allow-from '${var.vlans.public.cidr}'
      - set service dns forwarding allow-from '${var.vlans.private.cidr}'
      - set service dns forwarding allow-from '${var.vlans.system.cidr}'
      - set service dns forwarding allow-from '${var.vlans.data.cidr}'
      - set service dns forwarding listen-address '${var.vlans.public.gateway}'
      - set service dns forwarding listen-address '${var.vlans.private.gateway}'
      - set service dns forwarding listen-address '${var.vlans.system.gateway}'
      - set service dns forwarding listen-address '${var.vlans.data.gateway}'
      - set service dns forwarding system

      # ── Internal DNS zone (serves DHCP hostnames as FQDNs) ──
      # VMs that set a hostname in cloud-init become resolvable as
      # <hostname>.${var.dns_domain} from all VLANs via VyOS dnsmasq.
      - set service dns forwarding options 'local=/${var.dns_domain}/'
      - set service dns forwarding options 'expand-hosts'
      - set service dns forwarding options 'domain=${var.dns_domain}'

      # ══════════════════════════════════════
      # DHCP Servers — Per VLAN
      # ══════════════════════════════════════
      # Public VLAN
      - set service dhcp-server shared-network-name PUBLIC subnet ${var.vlans.public.cidr} range 0 start '${cidrhost(var.vlans.public.cidr, 100)}'
      - set service dhcp-server shared-network-name PUBLIC subnet ${var.vlans.public.cidr} range 0 stop '${cidrhost(var.vlans.public.cidr, 200)}'
      - set service dhcp-server shared-network-name PUBLIC subnet ${var.vlans.public.cidr} default-router '${var.vlans.public.gateway}'
      - set service dhcp-server shared-network-name PUBLIC subnet ${var.vlans.public.cidr} name-server '${var.vlans.public.gateway}'
      - set service dhcp-server shared-network-name PUBLIC subnet ${var.vlans.public.cidr} domain-name '${var.dns_domain}'
      # Private VLAN
      - set service dhcp-server shared-network-name PRIVATE subnet ${var.vlans.private.cidr} range 0 start '${cidrhost(var.vlans.private.cidr, 100)}'
      - set service dhcp-server shared-network-name PRIVATE subnet ${var.vlans.private.cidr} range 0 stop '${cidrhost(var.vlans.private.cidr, 200)}'
      - set service dhcp-server shared-network-name PRIVATE subnet ${var.vlans.private.cidr} default-router '${var.vlans.private.gateway}'
      - set service dhcp-server shared-network-name PRIVATE subnet ${var.vlans.private.cidr} name-server '${var.vlans.private.gateway}'
      - set service dhcp-server shared-network-name PRIVATE subnet ${var.vlans.private.cidr} domain-name '${var.dns_domain}'
      # System VLAN
      - set service dhcp-server shared-network-name SYSTEM subnet ${var.vlans.system.cidr} range 0 start '${cidrhost(var.vlans.system.cidr, 100)}'
      - set service dhcp-server shared-network-name SYSTEM subnet ${var.vlans.system.cidr} range 0 stop '${cidrhost(var.vlans.system.cidr, 200)}'
      - set service dhcp-server shared-network-name SYSTEM subnet ${var.vlans.system.cidr} default-router '${var.vlans.system.gateway}'
      - set service dhcp-server shared-network-name SYSTEM subnet ${var.vlans.system.cidr} name-server '${var.vlans.system.gateway}'
      - set service dhcp-server shared-network-name SYSTEM subnet ${var.vlans.system.cidr} domain-name '${var.dns_domain}'
      # Data VLAN
      - set service dhcp-server shared-network-name DATA subnet ${var.vlans.data.cidr} range 0 start '${cidrhost(var.vlans.data.cidr, 100)}'
      - set service dhcp-server shared-network-name DATA subnet ${var.vlans.data.cidr} range 0 stop '${cidrhost(var.vlans.data.cidr, 200)}'
      - set service dhcp-server shared-network-name DATA subnet ${var.vlans.data.cidr} default-router '${var.vlans.data.gateway}'
      - set service dhcp-server shared-network-name DATA subnet ${var.vlans.data.cidr} name-server '${var.vlans.data.gateway}'
      - set service dhcp-server shared-network-name DATA subnet ${var.vlans.data.cidr} domain-name '${var.dns_domain}'

      # ══════════════════════════════════════
      # FIREWALL — Zone-based policy
      # ══════════════════════════════════════

      # ── Zone definitions ──
      - set firewall zone WAN interface 'eth0'
      - set firewall zone WAN default-action 'drop'
      - set firewall zone PUBLIC interface 'eth1'
      - set firewall zone PUBLIC default-action 'drop'
      - set firewall zone PRIVATE interface 'eth2'
      - set firewall zone PRIVATE default-action 'drop'
      - set firewall zone SYSTEM interface 'eth3'
      - set firewall zone SYSTEM default-action 'drop'
      - set firewall zone DATA interface 'eth4'
      - set firewall zone DATA default-action 'drop'

      # ── All VLANs → WAN (internet) ──
      - set firewall ipv4 name ALLOW-INTERNET default-action 'drop'
      - set firewall ipv4 name ALLOW-INTERNET rule 10 action 'accept'
      - set firewall ipv4 name ALLOW-INTERNET rule 10 state 'established'
      - set firewall ipv4 name ALLOW-INTERNET rule 10 state 'related'
      - set firewall ipv4 name ALLOW-INTERNET rule 20 action 'accept'
      - set firewall zone WAN from PUBLIC firewall name 'ALLOW-INTERNET'
      - set firewall zone WAN from PRIVATE firewall name 'ALLOW-INTERNET'
      - set firewall zone WAN from SYSTEM firewall name 'ALLOW-INTERNET'
      - set firewall zone WAN from DATA firewall name 'ALLOW-INTERNET'

      # ── WAN → PUBLIC (inbound HTTP/HTTPS to LBs) ──
      - set firewall ipv4 name WAN-TO-PUBLIC default-action 'drop'
      - set firewall ipv4 name WAN-TO-PUBLIC rule 10 action 'accept'
      - set firewall ipv4 name WAN-TO-PUBLIC rule 10 state 'established'
      - set firewall ipv4 name WAN-TO-PUBLIC rule 10 state 'related'
      - set firewall ipv4 name WAN-TO-PUBLIC rule 20 action 'accept'
      - set firewall ipv4 name WAN-TO-PUBLIC rule 20 destination port '80,443'
      - set firewall ipv4 name WAN-TO-PUBLIC rule 20 protocol 'tcp'
      - set firewall zone PUBLIC from WAN firewall name 'WAN-TO-PUBLIC'

      # ── PUBLIC → PRIVATE (LB to K8s NodePort) ──
      - set firewall ipv4 name PUB-TO-PRIV default-action 'drop'
      - set firewall ipv4 name PUB-TO-PRIV rule 10 action 'accept'
      - set firewall ipv4 name PUB-TO-PRIV rule 10 state 'established'
      - set firewall ipv4 name PUB-TO-PRIV rule 10 state 'related'
      - set firewall ipv4 name PUB-TO-PRIV rule 20 action 'accept'
      - set firewall ipv4 name PUB-TO-PRIV rule 20 destination port '30000-32767'
      - set firewall ipv4 name PUB-TO-PRIV rule 20 protocol 'tcp'
      - set firewall ipv4 name PUB-TO-PRIV rule 20 description 'K8s NodePort range'
      - set firewall ipv4 name PUB-TO-PRIV rule 30 action 'accept'
      - set firewall ipv4 name PUB-TO-PRIV rule 30 destination port '6443'
      - set firewall ipv4 name PUB-TO-PRIV rule 30 protocol 'tcp'
      - set firewall ipv4 name PUB-TO-PRIV rule 30 description 'K8s API'
      - set firewall zone PRIVATE from PUBLIC firewall name 'PUB-TO-PRIV'

      # ── PRIVATE → SYSTEM (K8s to Vault + Registry) ──
      - set firewall ipv4 name PRIV-TO-SYS default-action 'drop'
      - set firewall ipv4 name PRIV-TO-SYS rule 10 action 'accept'
      - set firewall ipv4 name PRIV-TO-SYS rule 10 state 'established'
      - set firewall ipv4 name PRIV-TO-SYS rule 10 state 'related'
      - set firewall ipv4 name PRIV-TO-SYS rule 20 action 'accept'
      - set firewall ipv4 name PRIV-TO-SYS rule 20 destination port '8200'
      - set firewall ipv4 name PRIV-TO-SYS rule 20 protocol 'tcp'
      - set firewall ipv4 name PRIV-TO-SYS rule 20 description 'HashiCorp Vault API'
      - set firewall ipv4 name PRIV-TO-SYS rule 30 action 'accept'
      - set firewall ipv4 name PRIV-TO-SYS rule 30 destination port '5000,443'
      - set firewall ipv4 name PRIV-TO-SYS rule 30 protocol 'tcp'
      - set firewall ipv4 name PRIV-TO-SYS rule 30 description 'Container Registry'
      - set firewall ipv4 name PRIV-TO-SYS rule 40 action 'accept'
      - set firewall ipv4 name PRIV-TO-SYS rule 40 destination port '${var.kv_store_port}'
      - set firewall ipv4 name PRIV-TO-SYS rule 40 protocol 'tcp'
      - set firewall ipv4 name PRIV-TO-SYS rule 40 description 'KV Store (Redis/Consul)'
      - set firewall zone SYSTEM from PRIVATE firewall name 'PRIV-TO-SYS'

      # ── PRIVATE → DATA (K8s to databases) ──
      - set firewall ipv4 name PRIV-TO-DATA default-action 'drop'
      - set firewall ipv4 name PRIV-TO-DATA rule 10 action 'accept'
      - set firewall ipv4 name PRIV-TO-DATA rule 10 state 'established'
      - set firewall ipv4 name PRIV-TO-DATA rule 10 state 'related'
      - set firewall ipv4 name PRIV-TO-DATA rule 20 action 'accept'
      - set firewall ipv4 name PRIV-TO-DATA rule 20 destination port '5432'
      - set firewall ipv4 name PRIV-TO-DATA rule 20 protocol 'tcp'
      - set firewall ipv4 name PRIV-TO-DATA rule 20 description 'PostgreSQL'
      - set firewall ipv4 name PRIV-TO-DATA rule 30 action 'accept'
      - set firewall ipv4 name PRIV-TO-DATA rule 30 destination port '6379'
      - set firewall ipv4 name PRIV-TO-DATA rule 30 protocol 'tcp'
      - set firewall ipv4 name PRIV-TO-DATA rule 30 description 'Redis'
      - set firewall ipv4 name PRIV-TO-DATA rule 40 action 'accept'
      - set firewall ipv4 name PRIV-TO-DATA rule 40 destination port '9092'
      - set firewall ipv4 name PRIV-TO-DATA rule 40 protocol 'tcp'
      - set firewall ipv4 name PRIV-TO-DATA rule 40 description 'Kafka'
      - set firewall zone DATA from PRIVATE firewall name 'PRIV-TO-DATA'

      # ── SYSTEM → DATA (Vault DB backend) ──
      - set firewall ipv4 name SYS-TO-DATA default-action 'drop'
      - set firewall ipv4 name SYS-TO-DATA rule 10 action 'accept'
      - set firewall ipv4 name SYS-TO-DATA rule 10 state 'established'
      - set firewall ipv4 name SYS-TO-DATA rule 10 state 'related'
      - set firewall ipv4 name SYS-TO-DATA rule 20 action 'accept'
      - set firewall ipv4 name SYS-TO-DATA rule 20 destination port '5432'
      - set firewall ipv4 name SYS-TO-DATA rule 20 protocol 'tcp'
      - set firewall ipv4 name SYS-TO-DATA rule 20 description 'Vault PostgreSQL backend'
      - set firewall zone DATA from SYSTEM firewall name 'SYS-TO-DATA'

      # ── Return traffic from WAN → PUBLIC, SYSTEM, DATA ──
      - set firewall ipv4 name WAN-RETURN default-action 'drop'
      - set firewall ipv4 name WAN-RETURN rule 10 action 'accept'
      - set firewall ipv4 name WAN-RETURN rule 10 state 'established'
      - set firewall ipv4 name WAN-RETURN rule 10 state 'related'
      - set firewall zone PUBLIC from WAN firewall name 'WAN-RETURN'
      - set firewall zone SYSTEM from WAN firewall name 'WAN-RETURN'
      - set firewall zone DATA from WAN firewall name 'WAN-RETURN'

      # ── WAN → PRIVATE (Rancher API → RKE2 K8s API server) ──
      - set firewall ipv4 name WAN-TO-PRIV default-action 'drop'
      - set firewall ipv4 name WAN-TO-PRIV rule 10 action 'accept'
      - set firewall ipv4 name WAN-TO-PRIV rule 10 state 'established'
      - set firewall ipv4 name WAN-TO-PRIV rule 10 state 'related'
      - set firewall ipv4 name WAN-TO-PRIV rule 20 action 'accept'
      - set firewall ipv4 name WAN-TO-PRIV rule 20 source address '${var.rancher_mgmt_cidr}'
      - set firewall ipv4 name WAN-TO-PRIV rule 20 destination port '6443'
      - set firewall ipv4 name WAN-TO-PRIV rule 20 protocol 'tcp'
      - set firewall ipv4 name WAN-TO-PRIV rule 20 description 'Rancher → RKE2 K8s API'
      - set firewall zone PRIVATE from WAN firewall name 'WAN-TO-PRIV'

      # ── SSH access from mgmt ──
      - set service ssh port '22'
      - set service ssh listen-address '${var.vyos_mgmt_ip}'

    ssh_authorized_keys:
      - ${var.ssh_public_key}
  USERDATA

  # Network data for static management IP
  vyos_networkdata = <<-NETWORKDATA
    version: 2
    ethernets:
      eth0:
        addresses:
          - ${var.vyos_mgmt_ip}/${var.vyos_mgmt_cidr}
        gateway4: ${var.mgmt_network_gateway}
        nameservers:
          addresses:
            - ${var.upstream_dns[0]}
            - ${var.upstream_dns[1]}
  NETWORKDATA
}

# ── Cloud-init secrets ──
resource "harvester_cloudinit_secret" "vyos_config" {
  name      = "vyos-router-cloudinit"
  namespace = var.namespace

  user_data    = local.vyos_userdata
  network_data = local.vyos_networkdata
}
