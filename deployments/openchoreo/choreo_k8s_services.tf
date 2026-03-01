# ══════════════════════════════════════════════════════════════
# Kubernetes Services — OpenChoreo → Infrastructure VMs
#
# Creates Service + Endpoints objects so OpenChoreo components
# can reach PostgreSQL by cluster-native DNS names, without
# hardcoding VM IPs in Helm values.
#
# After applying:
#   postgres.default.svc.cluster.local:5432  → 10.N.3.10 (primary)
#   postgres-ro.default.svc.cluster.local    → 10.N.3.11 (standby)
#
# Extend coredns-custom ConfigMap to forward internal DNS zone
# queries (*.sre-<team>.internal) to VyOS — enabling FQDN-based
# access to VMs from K8s pods.
#
# NOTE: If you already applied service_dns.tf from the team workspace,
# the postgres/postgres-ro services already exist. This file is the
# standalone version for the openchoreo workspace.
# Remove this file if service_dns.tf is already applied in your team workspace.
# ══════════════════════════════════════════════════════════════

locals {
  # Compute service IPs from VLAN CIDRs — must match postgresql_ha.tf
  svc_pg_primary_ip = cidrhost(var.vlans.data.cidr, 10)
  svc_pg_standby_ip = cidrhost(var.vlans.data.cidr, 11)
}

# ── PostgreSQL primary — read/write ──
resource "kubernetes_service_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = var.choreo_app_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "database"
      "app.kubernetes.io/part-of"    = "openchoreo"
    }
  }

  spec {
    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_endpoints_v1" "postgres" {
  metadata {
    name      = kubernetes_service_v1.postgres.metadata[0].name
    namespace = var.choreo_app_namespace
  }

  subset {
    address {
      ip = local.svc_pg_primary_ip
    }
    port {
      name     = "postgres"
      port     = 5432
      protocol = "TCP"
    }
  }
}

# ── PostgreSQL standby — read-only ──
resource "kubernetes_service_v1" "postgres_ro" {
  metadata {
    name      = "postgres-ro"
    namespace = var.choreo_app_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "database-readonly"
      "app.kubernetes.io/part-of"    = "openchoreo"
    }
  }

  spec {
    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_endpoints_v1" "postgres_ro" {
  metadata {
    name      = kubernetes_service_v1.postgres_ro.metadata[0].name
    namespace = var.choreo_app_namespace
  }

  subset {
    address {
      ip = local.svc_pg_standby_ip
    }
    port {
      name     = "postgres"
      port     = 5432
      protocol = "TCP"
    }
  }
}

# ── CoreDNS stub zone ──
# Patches RKE2 CoreDNS to forward *.sre-<team>.internal queries to
# VyOS, so pods can reach VM FQDNs (e.g. choreo-id.sre-alpha.internal).
# RKE2 CoreDNS hot-reloads this ConfigMap automatically (~30s).
resource "kubernetes_config_map_v1" "coredns_stub_zone" {
  metadata {
    name      = "coredns-custom"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"       = "coredns"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    # File name must end in .server — CoreDNS imports it as a new server block
    "${replace(var.dns_domain, ".", "-")}.server" = <<-EOF
      # Stub zone: forward ${var.dns_domain} queries to VyOS dnsmasq
      # VyOS resolves VM hostnames from DHCP leases and static-host-mapping.
      ${var.dns_domain}:53 {
        forward . ${var.vlans.private.gateway}
        cache 30
        errors
        log
      }
    EOF
  }
}
