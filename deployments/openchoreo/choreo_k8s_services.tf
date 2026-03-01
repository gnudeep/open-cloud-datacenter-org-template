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
# CONFLICT GUARD:
#   If service_dns.tf is applied in your team-template workspace, set:
#     create_postgres_services = false
#   If coredns_stub_zone.tf is applied in your team-template workspace, set:
#     create_coredns_stub = false
#   These variables prevent duplicate-resource errors across workspaces.
# ══════════════════════════════════════════════════════════════

# ── PostgreSQL primary — read/write ──
resource "kubernetes_service_v1" "postgres" {
  count = var.create_postgres_services ? 1 : 0

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
  count = var.create_postgres_services ? 1 : 0

  metadata {
    name      = kubernetes_service_v1.postgres[0].metadata[0].name
    namespace = var.choreo_app_namespace
  }

  subset {
    address {
      ip = local.pg_primary_ip
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
  count = var.create_postgres_services ? 1 : 0

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
  count = var.create_postgres_services ? 1 : 0

  metadata {
    name      = kubernetes_service_v1.postgres_ro[0].metadata[0].name
    namespace = var.choreo_app_namespace
  }

  subset {
    address {
      ip = local.pg_standby_ip
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
# Set create_coredns_stub = false if coredns_stub_zone.tf manages this.
resource "kubernetes_config_map_v1" "coredns_stub_zone" {
  count = var.create_coredns_stub ? 1 : 0

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
