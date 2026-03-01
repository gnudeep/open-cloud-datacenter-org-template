# OpenChoreo Terraform Workspace

This directory is a standalone Terraform workspace that installs OpenChoreo v0.16+
on top of an existing team VPC. It must be applied **after** your team VPC workspace.

For the full deployment guide (architecture, database setup, troubleshooting), see
[`../openchoreo.md`](../openchoreo.md).

---

## File Map

| File | What it creates |
|------|----------------|
| `provider.tf` | Terraform + harvester / helm / kubernetes / null providers |
| `variables.tf` | All input variables with defaults and descriptions |
| `locals.tf` | Computed IPs, FQDNs, and connection strings |
| `data.tf` | Data sources — looks up PUBLIC VLAN network + Ubuntu image |
| `nginx_lb.tf` | Nginx proxy VM in PUBLIC VLAN (static IP, cloud-init, TLS copy) |
| `choreo_k8s_setup.tf` | `choreo-system` namespace + TLS / DB / OIDC K8s secrets |
| `choreo_prereqs.tf` | Gateway API CRDs, cert-manager, external-secrets |
| `thunder.tf` | Thunder OAuth2/OIDC IdP Helm release + readiness check |
| `openchoreo_cp.tf` | OpenChoreo control plane Helm release (API, Backstage, kgateway) |
| `openchoreo_dp.tf` | OpenChoreo data plane Helm release (agent, Cluster Gateway) |
| `choreo_k8s_services.tf` | K8s Service+Endpoints for PostgreSQL + CoreDNS stub zone |
| `outputs.tf` | Useful outputs + post-deploy checklist |
| `terraform.tfvars.example` | Complete variable reference — copy to `terraform.tfvars` |

---

## Prerequisites

Before running `terraform apply` in this workspace:

```
[ ] Team VPC workspace is applied (VyOS router running)
[ ] RKE2 cluster is Active in Rancher (rke2_cluster.tf applied in team workspace)
[ ] PostgreSQL is running with 'thunder' and 'backstage' databases created
    See: ../openchoreo.md Step 4 for SQL statements
[ ] extra_service_dns set in team VPC terraform.tfvars and applied:
      extra_service_dns = {
        "choreo"     = "10.N.0.10"
        "choreo-api" = "10.N.0.10"
        "choreo-id"  = "10.N.0.10"
      }
[ ] RKE2 kubeconfig downloaded from Rancher UI → saved as ./rke2-kubeconfig.yaml
[ ] TLS certificate generated (see terraform.tfvars.example)
[ ] kubectl >= 1.26 in PATH (needed for Gateway API CRD installation)
```

---

## Quick Start

### Step 1 — Prepare variables

```bash
cd deployments/openchoreo/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill in all ← REQUIRED fields
```

### Step 2 — Generate TLS certificate

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=*.sre-yourteam.internal" \
  -addext "subjectAltName=DNS:*.sre-yourteam.internal,DNS:sre-yourteam.internal"
```

### Step 3 — First apply (infra + prerequisites + Thunder)

On the first apply, leave `choreo_oidc_client_secret = ""`. The control plane install
will be skipped until this is set (Thunder must be running first).

```bash
terraform init
terraform apply -target=harvester_virtualmachine.nginx_lb \
                -target=null_resource.gateway_api_crds \
                -target=helm_release.cert_manager \
                -target=helm_release.thunder
```

### Step 4 — Register OIDC client in Thunder

After Thunder is running:

```bash
# Port-forward to Thunder admin UI
kubectl port-forward -n choreo-system svc/thunder 8080:8080

# Open in browser: http://localhost:8080/admin
# Create a new OIDC client:
#   Client ID:     choreo-control-plane
#   Client Type:   confidential
#   Redirect URIs: https://choreo-api.sre-yourteam.internal/callback
# Copy the generated client secret
```

### Step 5 — Complete install

```bash
# Set the OIDC client secret in terraform.tfvars
# choreo_oidc_client_secret = "the-secret-you-copied"

terraform apply    # installs control plane + data plane + K8s services
```

### Step 6 — Update Nginx with worker IP

```bash
# Get a RKE2 worker IP
kubectl get nodes -o wide | grep worker

# Update Nginx config
ssh ubuntu@10.N.0.10
sudo sed -i 's/RKE2_WORKER_IP/<actual-worker-ip>/g' /etc/nginx/sites-available/choreo
sudo nginx -t && sudo systemctl restart nginx
```

### Step 7 — Verify

```bash
# All pods should be Running
kubectl get pods -n choreo-system

# Developer portal
curl -k https://choreo.sre-yourteam.internal

# Thunder OIDC discovery
curl -k https://choreo-id.sre-yourteam.internal/.well-known/openid-configuration | jq .issuer
```

---

## Two-Stage Apply Pattern

Because the OIDC client secret can only be obtained after Thunder is running,
this workspace uses a two-stage apply:

```
Stage 1: nginx_lb + prereqs + Thunder
          ↓
     Register OIDC client in Thunder admin UI
          ↓
Stage 2: set choreo_oidc_client_secret + terraform apply
          → control plane + data plane install
```

This is intentional — it mirrors the real-world workflow where IdP client
registration is a manual step with approval.

---

## Destroy

```bash
# Remove OpenChoreo components (preserves Nginx VM and K8s cluster)
terraform destroy -target=helm_release.openchoreo_dp \
                  -target=helm_release.openchoreo_cp \
                  -target=helm_release.thunder

# Full destroy (removes Nginx VM too — team VPC and PostgreSQL are unaffected)
terraform destroy
```
