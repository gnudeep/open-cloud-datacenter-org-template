# ══════════════════════════════════════════════════════════════
# Nginx LB Proxy VM — PUBLIC VLAN
#
# This VM is the internet-facing entry point for OpenChoreo.
# It sits in the PUBLIC VLAN (10.N.0.x) and proxies HTTPS to
# the kgateway NodePort on RKE2 workers in the PRIVATE VLAN.
#
# Traffic path:
#   Internet :443 → Nginx VM (10.N.0.10) → K8s NodePort :30443
#   VyOS WAN-TO-PUBLIC rule 20 allows :80/:443 from internet
#   VyOS PUB-TO-PRIV rule 20 allows NodePort 30000-32767 to PRIVATE
#
# DNS:
#   choreo.sre-<team>.internal    → this VM's IP
#   choreo-api.sre-<team>.internal → this VM's IP
#   choreo-id.sre-<team>.internal  → this VM's IP
#   (registered via extra_service_dns in the team VPC workspace)
#
# After the VM is up, get an RKE2 worker IP and update the nginx
# config if needed. The cloud-init below uses the NodePort variables
# (default 30443/30080) to build the upstream config at first boot.
# ══════════════════════════════════════════════════════════════

resource "harvester_cloudinit_secret" "nginx_lb" {
  name      = "nginx-lb-cloudinit"
  namespace = var.namespace

  user_data = <<-USERDATA
    #cloud-config
    hostname: nginx-lb
    fqdn: nginx-lb.${var.dns_domain}
    manage_etc_hosts: true

    packages:
      - nginx

    write_files:
      # ── Nginx site config for OpenChoreo ──
      # The upstream block points to all RKE2 worker node IPs.
      # This single-entry example uses the first worker; add more
      # "server" lines for multiple workers (Nginx round-robins).
      - path: /etc/nginx/sites-available/choreo
        owner: root:root
        permissions: "0644"
        content: |
          upstream kgateway_backend {
            # Add one line per RKE2 worker node IP:
            server RKE2_WORKER_IP:${local.kgateway_https_nodeport};
          }

          # ── HTTPS — main entry point ──
          server {
            listen 443 ssl;
            server_name
              ${local.choreo_fqdn}
              ${local.choreo_api_fqdn}
              ${local.choreo_id_fqdn};

            ssl_certificate     /etc/ssl/choreo/tls.crt;
            ssl_certificate_key /etc/ssl/choreo/tls.key;
            ssl_protocols       TLSv1.2 TLSv1.3;

            # WebSocket support — required for Cluster Gateway (:8443)
            proxy_http_version 1.1;
            proxy_set_header   Upgrade $http_upgrade;
            proxy_set_header   Connection "upgrade";

            # Pass the original Host so kgateway can route by hostname
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;

            # kgateway uses its own TLS; disable cert verification
            # (cert is signed by the internal CA installed by cert-manager)
            proxy_ssl_verify off;

            location / {
              proxy_pass https://kgateway_backend;
            }
          }

          # ── HTTP → HTTPS redirect ──
          server {
            listen 80;
            server_name
              ${local.choreo_fqdn}
              ${local.choreo_api_fqdn}
              ${local.choreo_id_fqdn};
            return 301 https://$host$request_uri;
          }

      # ── Placeholder TLS certificate directory ──
      # The actual cert/key are copied by Terraform after VM boot
      # (see the null_resource "copy_nginx_tls" below).
      - path: /etc/ssl/choreo/.placeholder
        content: ""

    runcmd:
      - ln -sf /etc/nginx/sites-available/choreo /etc/nginx/sites-enabled/choreo
      - rm -f /etc/nginx/sites-enabled/default
      # Nginx starts automatically via package install.
      # It will fail until TLS certs are in place — that's expected.
      # The null_resource.copy_nginx_tls copies certs and restarts nginx.

    ssh_authorized_keys:
      - ${var.ssh_public_key}
  USERDATA

  # Static IP in PUBLIC VLAN
  network_data = <<-NETDATA
    version: 2
    ethernets:
      enp1s0:
        addresses:
          - ${local.choreo_lb_ip}/${local.public_prefix}
        gateway4: ${var.vlans.public.gateway}
        nameservers:
          addresses:
            - ${var.vlans.public.gateway}
          search:
            - ${var.dns_domain}
  NETDATA
}

resource "harvester_virtualmachine" "nginx_lb" {
  name      = "${var.namespace}-nginx-lb"
  namespace = var.namespace

  cpu    = var.nginx_vm_cpu
  memory = var.nginx_vm_memory

  disk {
    name        = "rootdisk"
    type        = "disk"
    size        = "10Gi"
    bus         = "virtio"
    boot_order  = 1
    image       = data.harvester_image.ubuntu.id
    auto_delete = true
  }

  network_interface {
    name         = "nic-public"
    model        = "virtio"
    type         = "bridge"
    network_name = data.harvester_network.public.id
  }

  cloudinit {
    user_data_secret_name    = harvester_cloudinit_secret.nginx_lb.name
    network_data_secret_name = harvester_cloudinit_secret.nginx_lb.name
  }

  tags = {
    "role"       = "nginx-lb"
    "service"    = "openchoreo"
    "service-ip" = local.choreo_lb_ip
  }

  depends_on = [data.harvester_network.public]
}

# ── Copy TLS certs to Nginx VM after it boots ──
# The VM is only accessible once it has a DHCP lease on the management/PUBLIC
# network. We SSH to it and place the certs from the paths in variables.
# If you prefer, skip this and SCP the certs manually.
resource "null_resource" "copy_nginx_tls" {
  triggers = {
    # Re-run if the cert file changes
    cert_sha = filesha256(var.choreo_tls_cert_path)
    key_sha  = filesha256(var.choreo_tls_key_path)
    vm_name  = harvester_virtualmachine.nginx_lb.name
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /etc/ssl/choreo",
      "sudo chmod 700 /etc/ssl/choreo",
    ]

    connection {
      type        = "ssh"
      host        = local.choreo_lb_ip
      user        = "ubuntu"
      private_key = file("~/.ssh/id_ed25519")   # adjust to your key path
      timeout     = "5m"
    }
  }

  provisioner "file" {
    source      = var.choreo_tls_cert_path
    destination = "/tmp/tls.crt"

    connection {
      type        = "ssh"
      host        = local.choreo_lb_ip
      user        = "ubuntu"
      private_key = file("~/.ssh/id_ed25519")
      timeout     = "5m"
    }
  }

  provisioner "file" {
    source      = var.choreo_tls_key_path
    destination = "/tmp/tls.key"

    connection {
      type        = "ssh"
      host        = local.choreo_lb_ip
      user        = "ubuntu"
      private_key = file("~/.ssh/id_ed25519")
      timeout     = "5m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /tmp/tls.crt /etc/ssl/choreo/tls.crt",
      "sudo mv /tmp/tls.key /etc/ssl/choreo/tls.key",
      "sudo chmod 640 /etc/ssl/choreo/tls.crt /etc/ssl/choreo/tls.key",
      "sudo nginx -t && sudo systemctl restart nginx",
    ]

    connection {
      type        = "ssh"
      host        = local.choreo_lb_ip
      user        = "ubuntu"
      private_key = file("~/.ssh/id_ed25519")
      timeout     = "5m"
    }
  }

  depends_on = [harvester_virtualmachine.nginx_lb]
}
