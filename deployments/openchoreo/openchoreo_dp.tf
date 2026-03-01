# ══════════════════════════════════════════════════════════════
# OpenChoreo Data Plane
#
# The data plane handles runtime API traffic. It installs:
#   - Data plane agent    (communicates with control plane)
#   - Cluster Gateway     (WebSocket bridge; port 8443)
#
# The data plane runs in the same K8s cluster as the control plane
# in this single-cluster setup. For multi-cluster deployments,
# apply this to each additional cluster separately.
#
# Prerequisites:
#   - OpenChoreo control plane is running (openchoreo_cp.tf applied)
# ══════════════════════════════════════════════════════════════

resource "helm_release" "openchoreo_dp" {
  name       = "openchoreo-data-plane"
  repository = "oci://ghcr.io/openchoreo/helm-charts"
  chart      = "openchoreo-data-plane"
  version    = var.openchoreo_version
  namespace  = var.choreo_system_namespace
  wait       = true
  timeout    = 300

  values = [<<-YAML
    # ── Control plane connection ──
    # The data plane agent connects to the control plane API.
    # Using cluster-internal endpoint for lower latency.
    controlPlane:
      url: "https://openchoreo-api.${var.choreo_system_namespace}.svc.cluster.local"
      # TLS — use the same cert-manager-issued cert
      tls:
        secretName: "choreo-tls"

    # ── Cluster Gateway ──
    # Handles WebSocket connections for real-time cluster communication.
    # Port 8443 is used for the gateway WebSocket.
    clusterGateway:
      port: 8443
      service:
        type: ClusterIP   # Internal only; control plane connects to it

    # ── Data plane identity ──
    # A unique name for this data plane registration in the control plane.
    identity:
      clusterName: "${var.namespace}-cluster"
      region:      "on-prem"
      environment: "production"

    # ── Resource sizing ──
    agent:
      resources:
        requests:
          cpu:    "100m"
          memory: "128Mi"
        limits:
          cpu:    "500m"
          memory: "256Mi"

    clusterGateway:
      resources:
        requests:
          cpu:    "100m"
          memory: "128Mi"
        limits:
          cpu:    "500m"
          memory: "256Mi"
  YAML
  ]

  depends_on = [helm_release.openchoreo_cp]
}
