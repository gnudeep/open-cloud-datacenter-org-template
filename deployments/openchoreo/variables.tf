# ══════════════════════════════════════════════════════════════
# OpenChoreo Deployment — Variables
# ══════════════════════════════════════════════════════════════

# ── Harvester connection ──
variable "harvester_kubeconfig" {
  description = "Path to Harvester kubeconfig file (team-scoped)"
  type        = string
  default     = "~/.kube/harvester.yaml"
}

# ── Namespace ──
variable "namespace" {
  description = "Your team's Harvester namespace (e.g. sre-alpha)"
  type        = string
}

# ── VLAN definitions — copy from your team VPC terraform.tfvars ──
variable "vlans" {
  description = "VLAN definitions from your team VPC. Used to compute reserved IPs and DNS gateways."
  type = map(object({
    vlan_id = number
    cidr    = string
    gateway = string
  }))
}

# ── DNS ──
variable "dns_domain" {
  description = "Internal DNS domain for this team's VPC (e.g. sre-alpha.internal)"
  type        = string
}

# ── SSH key ──
variable "ssh_public_key" {
  description = "SSH public key — placed on the Nginx proxy VM"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Absolute (or ~-prefixed) path to the SSH private key used to copy TLS certs to the Nginx VM. Example: ~/.ssh/id_ed25519"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

# ── Ubuntu image ──
variable "ubuntu_image_name" {
  description = "Display name of the Ubuntu image already uploaded to your Harvester namespace"
  type        = string
  default     = "ubuntu-22.04-server-cloudimg-amd64"
}

# ── RKE2 cluster ──
variable "rke2_kubeconfig_path" {
  description = "Path to RKE2 kubeconfig (download from Rancher UI: Cluster → Download KubeConfig)"
  type        = string
  default     = "./rke2-kubeconfig.yaml"
}

# ── Nginx LB proxy ──
variable "choreo_lb_ip" {
  description = <<-EOT
    Static IP for the Nginx LB proxy VM in the PUBLIC VLAN.
    Leave null to use the default: cidrhost(public.cidr, 10) = 10.N.0.10.
    Must match the IP set in extra_service_dns in your team VPC terraform.tfvars.
  EOT
  type        = string
  default     = null
}

variable "nginx_vm_cpu" {
  description = "Number of vCPUs for the Nginx proxy VM"
  type        = number
  default     = 1
}

variable "nginx_vm_memory" {
  description = "Memory for the Nginx proxy VM"
  type        = string
  default     = "1Gi"
}

# ── OpenChoreo DNS hostnames ──
variable "choreo_hostname" {
  description = "Short hostname for the Backstage developer portal. Full FQDN = <choreo_hostname>.<dns_domain>"
  type        = string
  default     = "choreo"
}

variable "choreo_api_hostname" {
  description = "Short hostname for the OpenChoreo API server"
  type        = string
  default     = "choreo-api"
}

variable "choreo_id_hostname" {
  description = "Short hostname for the Thunder OAuth2/OIDC identity provider"
  type        = string
  default     = "choreo-id"
}

# ── TLS certificates ──
variable "choreo_tls_cert_path" {
  description = <<-EOT
    Path to PEM TLS certificate for *.sre-<team>.internal.
    For a self-signed cert:
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout tls.key -out tls.crt \
        -subj "/CN=*.sre-yourteam.internal" \
        -addext "subjectAltName=DNS:*.sre-yourteam.internal"
  EOT
  type        = string
  default     = "./tls.crt"
}

variable "choreo_tls_key_path" {
  description = "Path to PEM TLS private key matching choreo_tls_cert_path"
  type        = string
  default     = "./tls.key"
}

# ── Database passwords ──
variable "thunder_db_password" {
  description = "Password for the 'thunder' PostgreSQL user (Thunder IdP database)"
  type        = string
  sensitive   = true
}

variable "backstage_db_password" {
  description = "Password for the 'backstage' PostgreSQL user (Backstage portal database)"
  type        = string
  sensitive   = true
}

# ── OpenChoreo OIDC client secret ──
variable "choreo_oidc_client_secret" {
  description = <<-EOT
    OIDC client secret registered in Thunder for the OpenChoreo control plane.
    Generate with: openssl rand -hex 32
    Register in Thunder admin UI after Thunder is deployed, then set this value.
  EOT
  type        = string
  sensitive   = true
}

# ── Chart versions ──
variable "cert_manager_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.14.5"
}

variable "external_secrets_version" {
  description = "external-secrets Helm chart version"
  type        = string
  default     = "0.9.17"
}

variable "gateway_api_version" {
  description = "Kubernetes Gateway API version for CRD installation"
  type        = string
  default     = "v1.2.0"
}

variable "openchoreo_version" {
  description = "OpenChoreo Helm chart version (applies to thunder, openchoreo, openchoreo-data-plane)"
  type        = string
  default     = "0.16.0"
}

# ── kgateway NodePorts ──
# Fixed NodePorts avoid the chicken-and-egg problem of needing NodePorts before Nginx config.
# These are passed to the OpenChoreo Helm chart and must match the Nginx proxy config.
variable "kgateway_https_nodeport" {
  description = "Fixed NodePort for kgateway HTTPS (must be in 30000-32767 range)"
  type        = number
  default     = 30443
}

variable "kgateway_http_nodeport" {
  description = "Fixed NodePort for kgateway HTTP (redirects to HTTPS)"
  type        = number
  default     = 30080
}

# ── Conditional resource creation ──
variable "create_postgres_services" {
  description = <<-EOT
    Set to false if the postgres and postgres-ro K8s Services already exist in the
    cluster (e.g. created by service_dns.tf in your team-template workspace).
    Prevents duplicate-resource errors when both workspaces target the same cluster.
  EOT
  type        = bool
  default     = true
}

variable "create_coredns_stub" {
  description = <<-EOT
    Set to false if the coredns-custom ConfigMap is already managed by
    coredns_stub_zone.tf in your team-template workspace.
    Prevents ownership conflicts — only one workspace should own this ConfigMap.
  EOT
  type        = bool
  default     = true
}

# ── K8s namespaces ──
variable "choreo_system_namespace" {
  description = "Kubernetes namespace for OpenChoreo system components"
  type        = string
  default     = "choreo-system"
}

variable "choreo_app_namespace" {
  description = "Kubernetes namespace for application-level K8s Services (postgres, redis)"
  type        = string
  default     = "default"
}
