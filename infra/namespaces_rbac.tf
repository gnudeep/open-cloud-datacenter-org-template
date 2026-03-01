# ══════════════════════════════════════════════════════════════
# Per-Team ServiceAccounts and Kubernetes RBAC
#
# Namespaces are created via rancher2_namespace in rancher.tf.
# This file adds the k8s ServiceAccount and fine-grained RBAC
# that each team's Terraform kubeconfig uses.
# ══════════════════════════════════════════════════════════════

# ── Stamp each namespace with its authoritative VLAN allowlist ──
# This annotation is the single source of truth consumed by:
#   1. The Kyverno ClusterPolicy (infra/kyverno/vlan-policy.yaml)
#   2. The audit script (scripts/audit-vlans.sh)
# It is set by the platform team and SRE teams cannot modify it
# (they lack permission to PATCH their own namespace object).
resource "kubernetes_annotations" "sre_vlan_allowlist" {
  for_each = var.sre_teams

  api_version = "v1"
  kind        = "Namespace"

  metadata {
    name = rancher2_namespace.sre_teams[each.key].name
  }

  annotations = {
    "platform/allowed-vlans" = join(",", [
      tostring(100 + (each.value.offset - 1) * 10),
      tostring(200 + (each.value.offset - 1) * 10),
      tostring(300 + (each.value.offset - 1) * 10),
      tostring(400 + (each.value.offset - 1) * 10),
    ])
    "platform/team-offset"  = tostring(each.value.offset)
    "platform/subnet-block" = "10.${each.value.offset}.0.0/22"
    "platform/vyos-mgmt-ip" = "192.168.1.${each.value.offset * 10}"
  }

  depends_on = [rancher2_namespace.sre_teams]
}

# ── ServiceAccount per SRE team (used for team Terraform kubeconfig) ──
resource "kubernetes_service_account" "sre_deployers" {
  for_each = var.sre_teams

  metadata {
    name      = "${each.key}-deployer"
    namespace = rancher2_namespace.sre_teams[each.key].name

    labels = {
      "managed-by" = "platform-infra"
    }

    annotations = {
      "platform/team-offset"  = tostring(each.value.offset)
      "platform/vlan-public"  = tostring(100 + (each.value.offset - 1) * 10)
      "platform/vlan-private" = tostring(200 + (each.value.offset - 1) * 10)
      "platform/vlan-system"  = tostring(300 + (each.value.offset - 1) * 10)
      "platform/vlan-data"    = tostring(400 + (each.value.offset - 1) * 10)
      "platform/subnet-block" = "10.${each.value.offset}.0.0/22"
      "platform/vyos-mgmt-ip" = "192.168.1.${each.value.offset * 10}"
    }
  }

  depends_on = [rancher2_namespace.sre_teams]
}

# ── RoleBinding: standard Kubernetes edit access per namespace ──
resource "kubernetes_role_binding" "sre_edit" {
  for_each = var.sre_teams

  metadata {
    name      = "${each.key}-edit"
    namespace = rancher2_namespace.sre_teams[each.key].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "edit"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.sre_deployers[each.key].metadata[0].name
    namespace = rancher2_namespace.sre_teams[each.key].name
  }
}

# ── ClusterRole for Harvester CRDs ──
# The built-in 'edit' ClusterRole covers core k8s resources.
# This role adds the Harvester-specific CRDs teams need for VMs/networks.
resource "kubernetes_cluster_role" "harvester_namespace_user" {
  metadata {
    name = "harvester-namespace-user"

    labels = {
      "managed-by" = "platform-infra"
    }
  }

  rule {
    api_groups = ["kubevirt.io"]
    resources  = ["virtualmachines", "virtualmachineinstances"]
    verbs      = ["*"]
  }

  rule {
    api_groups = ["subresources.kubevirt.io"]
    resources  = ["virtualmachines/start", "virtualmachines/stop", "virtualmachines/restart"]
    verbs      = ["update"]
  }

  rule {
    api_groups = ["harvesterhci.io"]
    resources  = ["virtualmachineimages", "keypairs", "virtualmachinebackups", "virtualmachinerestores"]
    verbs      = ["*"]
  }

  rule {
    api_groups = ["k8s.cni.cncf.io"]
    resources  = ["network-attachment-definitions"]
    verbs      = ["*"]
  }

  rule {
    api_groups = [""]
    resources  = ["secrets", "configmaps", "persistentvolumeclaims"]
    verbs      = ["*"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

# ── RoleBinding: Harvester CRD access per namespace ──
resource "kubernetes_role_binding" "sre_harvester" {
  for_each = var.sre_teams

  metadata {
    name      = "${each.key}-harvester-user"
    namespace = rancher2_namespace.sre_teams[each.key].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.harvester_namespace_user.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.sre_deployers[each.key].metadata[0].name
    namespace = rancher2_namespace.sre_teams[each.key].name
  }
}
