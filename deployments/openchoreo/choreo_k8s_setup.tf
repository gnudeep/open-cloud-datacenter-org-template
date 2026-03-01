# ══════════════════════════════════════════════════════════════
# K8s Namespace and Secrets — choreo-system
#
# Creates:
#   1. choreo-system namespace
#   2. choreo-tls   — TLS certificate secret (kubernetes.io/tls type)
#   3. choreo-db    — Database connection strings for Thunder + Backstage
#
# All secrets are created before any Helm release so that
# Thunder and OpenChoreo can reference them by name in values.yaml.
# ══════════════════════════════════════════════════════════════

# ── Namespace ──
resource "kubernetes_namespace_v1" "choreo_system" {
  metadata {
    name = var.choreo_system_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "openchoreo"
    }
  }
}

# ── TLS secret ──
# Used by Thunder, Backstage, and kgateway for HTTPS termination.
# Generate certs with openssl (self-signed) or provide Let's Encrypt certs.
resource "kubernetes_secret_v1" "choreo_tls" {
  metadata {
    name      = "choreo-tls"
    namespace = var.choreo_system_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = file(var.choreo_tls_cert_path)
    "tls.key" = file(var.choreo_tls_key_path)
  }

  depends_on = [kubernetes_namespace_v1.choreo_system]
}

# ── Database credentials — Thunder IdP ──
resource "kubernetes_secret_v1" "thunder_db" {
  metadata {
    name      = "thunder-db-credentials"
    namespace = var.choreo_system_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "thunder"
    }
  }

  data = {
    # Full connection URL — Thunder reads this from env var THUNDER_DATABASE_URL
    "database-url" = local.pg_thunder_url
    # Individual fields — used by some chart value paths
    "host"     = "postgres.${var.choreo_app_namespace}.svc.cluster.local"
    "port"     = "5432"
    "database" = "thunder"
    "username" = "thunder"
    "password" = var.thunder_db_password
  }

  depends_on = [kubernetes_namespace_v1.choreo_system]
}

# ── Database credentials — Backstage developer portal ──
resource "kubernetes_secret_v1" "backstage_db" {
  metadata {
    name      = "backstage-db-credentials"
    namespace = var.choreo_system_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "backstage"
    }
  }

  data = {
    "database-url" = local.pg_backstage_url
    "host"         = "postgres.${var.choreo_app_namespace}.svc.cluster.local"
    "port"         = "5432"
    "database"     = "backstage"
    "username"     = "backstage"
    "password"     = var.backstage_db_password
  }

  depends_on = [kubernetes_namespace_v1.choreo_system]
}

# ── OIDC client secret — OpenChoreo control plane ↔ Thunder ──
resource "kubernetes_secret_v1" "choreo_oidc" {
  metadata {
    name      = "choreo-oidc-credentials"
    namespace = var.choreo_system_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "openchoreo"
    }
  }

  data = {
    # The control plane authenticates to Thunder using these credentials.
    # Register the client in Thunder admin UI first, then set choreo_oidc_client_secret.
    "client-id"     = "choreo-control-plane"
    "client-secret" = var.choreo_oidc_client_secret
  }

  depends_on = [kubernetes_namespace_v1.choreo_system]
}
