# ══════════════════════════════════════════════════════════════
# SSH Key & VM Images
# ══════════════════════════════════════════════════════════════

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
