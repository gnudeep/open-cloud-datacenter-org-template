# ══════════════════════════════════════════════════════════════
# OpenChoreo Control Plane
#
# Installs:
#   - OpenChoreo API server   (SQLite-backed; no PostgreSQL needed)
#   - Controller Manager      (reconciles OpenChoreo CRDs)
#   - Backstage               (developer portal; PostgreSQL-backed)
#   - kgateway                (Envoy-based API gateway; NodePort mode)
#
# Prerequisites:
#   - Thunder is running and OIDC discovery is serving
#   - choreo_oidc_client_secret is set (from Thunder admin UI)
#   - cert-manager is installed
#   - Gateway API CRDs are installed
# ══════════════════════════════════════════════════════════════

resource "helm_release" "openchoreo_cp" {
  name       = "openchoreo"
  repository = "oci://ghcr.io/openchoreo/helm-charts"
  chart      = "openchoreo"
  version    = var.openchoreo_version
  namespace  = var.choreo_system_namespace
  wait       = true
  timeout    = 600

  values = [<<-YAML
    # ── Global public-facing URLs ──
    global:
      portalUrl:   "https://${local.choreo_fqdn}"
      apiUrl:      "https://${local.choreo_api_fqdn}"
      identityUrl: "https://${local.choreo_id_fqdn}"

    # ── Thunder OIDC configuration ──
    # The control plane registers as an OIDC client in Thunder.
    thunder:
      url: "https://thunder.${var.choreo_system_namespace}.svc.cluster.local:8443"
      oidc:
        existingSecret: "choreo-oidc-credentials"
        secretKeys:
          clientId:     "client-id"
          clientSecret: "client-secret"
      # Thunder's OIDC discovery endpoint — used to validate tokens
      issuerUrl: "https://${local.choreo_id_fqdn}"

    # ── Backstage developer portal ──
    backstage:
      database:
        existingSecret: "backstage-db-credentials"
        secretKeys:
          databaseUrl: "database-url"
      config:
        app:
          title:   "OpenChoreo Developer Portal"
          baseUrl: "https://${local.choreo_fqdn}"
        backend:
          baseUrl: "https://${local.choreo_fqdn}"
          cors:
            origin: "https://${local.choreo_fqdn}"
      resources:
        requests:
          cpu:    "200m"
          memory: "512Mi"
        limits:
          cpu:    "1000m"
          memory: "1Gi"

    # ── kgateway (API gateway) ──
    # Set to NodePort so the Nginx proxy in PUBLIC VLAN can reach it.
    # The fixed NodePorts must match kgateway_https_nodeport in variables.tf.
    kgateway:
      service:
        type:          NodePort
        httpNodePort:  ${local.kgateway_http_nodeport}
        httpsNodePort: ${local.kgateway_https_nodeport}
      resources:
        requests:
          cpu:    "100m"
          memory: "128Mi"
        limits:
          cpu:    "500m"
          memory: "256Mi"

    # ── TLS ──
    tls:
      secretName: "choreo-tls"

    # ── cert-manager issuer for internal service TLS ──
    certManager:
      issuerRef:
        name: "internal-ca"
        kind: "ClusterIssuer"

    # ── Resource sizing ──
    api:
      resources:
        requests:
          cpu:    "200m"
          memory: "256Mi"
        limits:
          cpu:    "1000m"
          memory: "512Mi"

    controllerManager:
      resources:
        requests:
          cpu:    "100m"
          memory: "128Mi"
        limits:
          cpu:    "500m"
          memory: "256Mi"
  YAML
  ]

  depends_on = [
    null_resource.wait_for_thunder,
    kubernetes_secret_v1.backstage_db,
    kubernetes_secret_v1.choreo_oidc,
    kubernetes_secret_v1.choreo_tls,
    kubernetes_manifest.internal_ca_issuer,
    null_resource.gateway_api_crds,
  ]
}
