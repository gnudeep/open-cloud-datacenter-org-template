# ══════════════════════════════════════════════════════════════
# Kubernetes Prerequisites for OpenChoreo
#
# Install order:
#   1. Gateway API CRDs  (null_resource — requires kubectl in PATH)
#   2. cert-manager      (Helm)
#   3. external-secrets  (Helm, optional but recommended)
#
# These must all complete before Thunder or OpenChoreo are installed.
# ══════════════════════════════════════════════════════════════

# ── 1. Gateway API CRDs ──
# kgateway (OpenChoreo's API gateway) requires the standard Gateway API CRDs.
# There is no official Helm chart for these — they are applied via kubectl.
# Requires: kubectl >= 1.26 in PATH with KUBECONFIG pointing to RKE2 cluster.
#
# The --server-side flag uses server-side apply which handles large CRD objects
# and prevents "metadata.annotations too long" errors.
resource "null_resource" "gateway_api_crds" {
  triggers = {
    # Re-apply if the Gateway API version changes
    version    = var.gateway_api_version
    kubeconfig = var.rke2_kubeconfig_path
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = var.rke2_kubeconfig_path
    }
    command = <<-CMD
      kubectl apply --server-side -f \
        https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml && \
      kubectl apply --server-side -f \
        https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/experimental-install.yaml
    CMD
  }
}

# ── 2. cert-manager ──
# Manages TLS certificates for inter-service communication inside K8s.
# kgateway and Thunder both rely on cert-manager-issued certificates.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "oci://ghcr.io/cert-manager/charts"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "installCRDs"
    value = "true"
  }

  # Disable leader election — not needed in single-controller setups
  set {
    name  = "global.leaderElection.namespace"
    value = "cert-manager"
  }

  depends_on = [null_resource.gateway_api_crds]
}

# ── cert-manager ClusterIssuer — self-signed root CA ──
# Creates a self-signed CA that cert-manager uses to issue internal TLS certs.
# For production, replace with a Let's Encrypt or corporate CA issuer.
resource "kubernetes_manifest" "selfsigned_clusterissuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "selfsigned"
    }
    spec = {
      selfSigned = {}
    }
  }

  depends_on = [helm_release.cert_manager]
}

resource "kubernetes_manifest" "internal_ca_cert" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "internal-ca"
      namespace = "cert-manager"
    }
    spec = {
      isCA       = true
      commonName = "internal-ca"
      secretName = "internal-ca-secret"
      privateKey = { algorithm = "ECDSA", size = 256 }
      issuerRef  = { name = "selfsigned", kind = "ClusterIssuer" }
    }
  }

  depends_on = [kubernetes_manifest.selfsigned_clusterissuer]
}

resource "kubernetes_manifest" "internal_ca_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "internal-ca"
    }
    spec = {
      ca = { secretName = "internal-ca-secret" }
    }
  }

  depends_on = [kubernetes_manifest.internal_ca_cert]
}

# ── 3. external-secrets (optional) ──
# Syncs secrets from external stores (Vault, AWS Secrets Manager, etc.) into K8s.
# Remove this resource if you are not using an external secret store.
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "oci://ghcr.io/external-secrets/charts"
  chart            = "external-secrets"
  version          = var.external_secrets_version
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [helm_release.cert_manager]
}
