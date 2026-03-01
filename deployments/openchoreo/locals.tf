# ══════════════════════════════════════════════════════════════
# OpenChoreo Deployment — Local Values
# ══════════════════════════════════════════════════════════════

locals {
  # ── IP addresses ──
  # Nginx LB proxy IP in PUBLIC VLAN (default: .10 of public subnet)
  choreo_lb_ip = coalesce(var.choreo_lb_ip, cidrhost(var.vlans.public.cidr, 10))

  # PostgreSQL IPs in DATA VLAN — must match postgresql_ha.tf in team workspace
  pg_primary_ip = cidrhost(var.vlans.data.cidr, 10)
  pg_standby_ip = cidrhost(var.vlans.data.cidr, 11)

  # Network prefix lengths
  public_prefix = split("/", var.vlans.public.cidr)[1]

  # ── FQDNs ──
  choreo_fqdn     = "${var.choreo_hostname}.${var.dns_domain}"
  choreo_api_fqdn = "${var.choreo_api_hostname}.${var.dns_domain}"
  choreo_id_fqdn  = "${var.choreo_id_hostname}.${var.dns_domain}"

  # ── Database connection strings ──
  # These use K8s cluster-native names (from service_dns.tf in team workspace).
  # Pods resolve these via CoreDNS → postgres.default.svc.cluster.local.
  pg_thunder_url   = "postgresql://thunder:${var.thunder_db_password}@postgres.${var.choreo_app_namespace}.svc.cluster.local:5432/thunder"
  pg_backstage_url = "postgresql://backstage:${var.backstage_db_password}@postgres.${var.choreo_app_namespace}.svc.cluster.local:5432/backstage"

  # ── Nginx upstream ──
  # Populated after OpenChoreo install — see outputs for how to get NodePort.
  # The Nginx config references the NodePort variable set in cloud-init.
  kgateway_https_nodeport = var.kgateway_https_nodeport
  kgateway_http_nodeport  = var.kgateway_http_nodeport
}
