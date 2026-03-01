# ══════════════════════════════════════════════════════════════
# Rancher2 — Project and Namespace Management
# Creates one Rancher project per SRE team and registers each
# team's Kubernetes namespace inside that project.
# ══════════════════════════════════════════════════════════════

# ── One Rancher project per SRE team ──
resource "rancher2_project" "sre_teams" {
  for_each = var.sre_teams

  name       = each.key
  cluster_id = var.rancher_cluster_id

  description = "SRE team project — ${each.key} (VLAN offset ${each.value.offset})"

  # Soft resource quotas — adjust per team requirements
  resource_quota {
    project_limit {
      limits_cpu    = "16000m"
      limits_memory = "32768Mi"
    }
    namespace_default_limit {
      limits_cpu    = "4000m"
      limits_memory = "8192Mi"
    }
  }

  container_resource_limit {
    limits_cpu      = "1000m"
    limits_memory   = "1024Mi"
    requests_cpu    = "100m"
    requests_memory = "128Mi"
  }
}

# ── Register each team namespace under its Rancher project ──
# This replaces the bare kubernetes_namespace resource and ensures
# Rancher project membership is set correctly from creation.
resource "rancher2_namespace" "sre_teams" {
  for_each = var.sre_teams

  name       = each.key
  project_id = rancher2_project.sre_teams[each.key].id

  description = "Namespace for ${each.key} SRE team"

  labels = {
    "team"        = each.key
    "managed-by"  = "platform-infra"
    "team-offset" = tostring(each.value.offset)
  }

  # Namespace-level resource quota (subset of project quota)
  resource_quota {
    limit {
      limits_cpu    = "4000m"
      limits_memory = "8192Mi"
    }
  }
}
