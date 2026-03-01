# ══════════════════════════════════════════════════════════════
# OpenChoreo Deployment — Outputs
# ══════════════════════════════════════════════════════════════

output "nginx_lb_ip" {
  value       = local.choreo_lb_ip
  description = "Static IP of the Nginx LB proxy VM in PUBLIC VLAN"
}

output "choreo_urls" {
  value = {
    portal   = "https://${local.choreo_fqdn}"
    api      = "https://${local.choreo_api_fqdn}"
    identity = "https://${local.choreo_id_fqdn}"
  }
  description = "Public-facing OpenChoreo URLs"
}

output "kgateway_nodeports" {
  value = {
    http  = var.kgateway_http_nodeport
    https = var.kgateway_https_nodeport
  }
  description = "Fixed NodePorts assigned to kgateway — used by the Nginx proxy"
}

output "db_service_dns" {
  value = {
    postgres    = "postgres.${var.choreo_app_namespace}.svc.cluster.local:5432"
    postgres_ro = "postgres-ro.${var.choreo_app_namespace}.svc.cluster.local:5432"
  }
  description = "Cluster-native DNS names for PostgreSQL services"
}

output "thunder_health_check" {
  value       = "kubectl exec -n ${var.choreo_system_namespace} deploy/thunder -- wget -qO- http://localhost:8080/.well-known/openid-configuration"
  description = "Command to verify Thunder OIDC discovery is serving"
}

output "next_steps" {
  value = <<-EOT

    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    OpenChoreo Deployment Complete
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    1. Get RKE2 worker IPs:
       kubectl get nodes -o wide

    2. Update Nginx config with a real worker IP:
       ssh ubuntu@${local.choreo_lb_ip}
       sudo sed -i 's/RKE2_WORKER_IP/<actual-worker-ip>/g' \
         /etc/nginx/sites-available/choreo
       sudo nginx -t && sudo systemctl restart nginx

    3. Verify kgateway is running:
       kubectl get pods -n ${var.choreo_system_namespace}

    4. Access the developer portal:
       https://${local.choreo_fqdn}

    5. Access Thunder admin UI (create OIDC client for control plane):
       https://${local.choreo_id_fqdn}/admin

    6. After creating the OIDC client in Thunder:
       Set choreo_oidc_client_secret in terraform.tfvars
       terraform apply   (OpenChoreo CP will pick up the secret)

    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  EOT
  description = "Post-deployment checklist"
}
