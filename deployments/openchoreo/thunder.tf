# ══════════════════════════════════════════════════════════════
# Thunder — OAuth2/OIDC Identity Provider
#
# Thunder is OpenChoreo's built-in IdP. It must be installed and
# healthy BEFORE the OpenChoreo control plane, because the control
# plane registers as an OIDC client at startup.
#
# Thunder connects to PostgreSQL via the 'thunder' database.
# Connection string is read from the choreo-db-credentials secret.
#
# After Thunder is installed:
#   1. Access Thunder admin UI at https://choreo-id.<team>.internal/admin
#   2. Register an OIDC client named "choreo-control-plane"
#   3. Copy the generated client secret
#   4. Set choreo_oidc_client_secret in terraform.tfvars
#   5. Run terraform apply (openchoreo_cp.tf picks it up)
# ══════════════════════════════════════════════════════════════

resource "helm_release" "thunder" {
  name       = "thunder"
  repository = "oci://ghcr.io/openchoreo/helm-charts"
  chart      = "thunder"
  version    = var.openchoreo_version
  namespace  = var.choreo_system_namespace
  wait       = true
  timeout    = 600 # Thunder runs DB migrations on first boot

  values = [<<-YAML
    # ── Database ──
    database:
      existingSecret: "thunder-db-credentials"
      secretKeys:
        databaseUrl: "database-url"

    # ── Public-facing URLs ──
    # Thunder issues tokens with the issuerUrl as the 'iss' claim.
    # This MUST match the URL clients use to discover the OIDC config.
    config:
      issuerUrl: "https://${local.choreo_id_fqdn}"
      # Admin UI — accessible via the same LB proxy
      adminUrl:  "https://${local.choreo_id_fqdn}/admin"

    # ── TLS ──
    tls:
      enabled: true
      secretName: "choreo-tls"

    # ── Service — ClusterIP; traffic comes from Nginx via NodePort ──
    service:
      type: ClusterIP

    # ── Ingress — disabled; Nginx proxy + kgateway handles ingress ──
    ingress:
      enabled: false

    # ── Resource sizing ──
    resources:
      requests:
        cpu:    "100m"
        memory: "256Mi"
      limits:
        cpu:    "500m"
        memory: "512Mi"
  YAML
  ]

  depends_on = [
    kubernetes_namespace_v1.choreo_system,
    kubernetes_secret_v1.thunder_db,
    kubernetes_secret_v1.choreo_tls,
    helm_release.cert_manager,
  ]
}

# ── Wait for Thunder to be ready before control plane install ──
# The control plane contacts Thunder at startup. This null_resource
# polls the OIDC discovery endpoint before proceeding.
resource "null_resource" "wait_for_thunder" {
  triggers = {
    thunder_version = var.openchoreo_version
    thunder_release = helm_release.thunder.id
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = var.rke2_kubeconfig_path
    }
    command = <<-CMD
      echo "Waiting for Thunder to serve OIDC discovery..."
      for i in $(seq 1 30); do
        STATUS=$(kubectl exec -n ${var.choreo_system_namespace} \
          $(kubectl get pod -n ${var.choreo_system_namespace} -l app.kubernetes.io/name=thunder \
            -o jsonpath='{.items[0].metadata.name}') \
          -- wget -qO- http://localhost:8080/.well-known/openid-configuration 2>/dev/null \
          | grep -c '"issuer"' || true)
        if [ "$STATUS" = "1" ]; then
          echo "Thunder is ready."
          exit 0
        fi
        echo "  attempt $i/30 — not ready yet, waiting 10s..."
        sleep 10
      done
      echo "ERROR: Thunder did not become ready in 5 minutes."
      exit 1
    CMD
  }

  depends_on = [helm_release.thunder]
}
