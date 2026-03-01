# ══════════════════════════════════════════════════════════════
# SSH Key & VM Images
# ══════════════════════════════════════════════════════════════

# ── Ubuntu Cloud Image ──
# Looks up an existing Ubuntu image in your namespace by display name.
# Upload the image once via Harvester UI or:
#   kubectl -n <namespace> apply -f ubuntu-image.yaml
data "harvester_image" "ubuntu" {
  display_name = var.ubuntu_image_name
  namespace    = var.namespace
}

resource "harvester_ssh_key" "vpc_key" {
  name       = "vpc-ssh-key"
  namespace  = var.namespace
  public_key = var.ssh_public_key
}

# ── VyOS Router Image ──
resource "harvester_image" "vyos" {
  name         = "vyos-router"
  namespace    = var.namespace
  display_name = "VyOS Rolling Cloud-Init"
  source_type  = "download"
  url          = var.vyos_image_url

  timeouts {
    create = "15m"
    update = "15m"
    delete = "2m"
  }
}
