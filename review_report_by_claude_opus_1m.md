# Repository Review Report

**Repository:** lk-dc-org-template
**Reviewed by:** Claude Opus (1M context)
**Date:** 2026-03-01
**Scope:** Full repository — architecture, Terraform code, documentation, security, and operational readiness

---

## Executive Summary

This repository implements a **multi-team VPC-like network isolation platform** on Harvester HCI 1.7.1 using VyOS router VMs and VLAN segmentation. It is well-architected, thoroughly documented, and demonstrates mature infrastructure-as-code practices. The two-layer model (platform `infra/` vs team `team-template/`) cleanly separates concerns and enables safe multi-tenancy on shared bare-metal infrastructure.

**Overall assessment: Production-ready for lab/staging environments.** A handful of issues (mainly in the root-level legacy files and security hardening) should be addressed before full production deployment.

**Rating: 8.5/10**

---

## 1. Architecture Review

### Strengths

- **Clean two-layer separation.** The `infra/` module handles cluster-scoped resources (ClusterNetwork, VLANConfig, Namespaces, RBAC) while `team-template/` is namespace-scoped. This maps directly to the trust boundary — platform admins vs. SRE teams.
- **Deterministic VLAN allocation formula.** The `100+(N-1)*10` formula for VLAN IDs and `10.N.x.0/24` for subnets is simple, predictable, and well-documented. It avoids the need for a separate IPAM system.
- **VyOS as a per-team router** provides strong L2/L3 isolation between teams without requiring physical switch ACLs per team. Each team owns their firewall policy.
- **Four-zone model** (public/private/system/data) maps cleanly to a standard three-tier application architecture plus a dedicated data tier.
- **DNS design is elegant.** The two-layer approach (VyOS dnsmasq for VM-level DNS + CoreDNS stub zone for K8s pod access) provides seamless service discovery without extra infrastructure.

### Concerns

| # | Concern | Severity | Location |
|---|---------|----------|----------|
| A1 | **Single VyOS router per team = SPOF.** No HA for the VyOS router VM. If it goes down, the entire team VPC is unreachable. | Medium | `team-template/vyos_router.tf` |
| A2 | **No backup/restore strategy** documented for VyOS configuration or PostgreSQL data. | Medium | Documentation gap |
| A3 | **Scalability ceiling at 10 teams** with 10-step VLAN offsets (100,110,...,190). Documented but easy to forget. | Low | `AGENT.md` Section 11 |
| A4 | **Cross-team traffic is "blocked by default" only at L2** — there is no explicit VyOS deny rule between team subnets. If a team misconfigures routing, traffic could theoretically reach another team's subnet. | Low | `cloudinit.tf` |

### Recommendations

1. **A1:** Document VyOS HA options (VRRP pair, or KubeVirt VM live migration) for production use.
2. **A2:** Add a `backups/` section to documentation covering VyOS config export (`show configuration commands > backup.txt`) and PostgreSQL `pg_basebackup` scheduling.
3. **A4:** Consider adding explicit inter-VPC deny rules in VyOS (e.g., `set firewall ipv4 name BLOCK-OTHER-VPCS rule 10 destination address 10.0.0.0/8 action drop`) to guarantee team isolation even if routing is misconfigured.

---

## 2. Terraform Code Quality

### Strengths

- **Consistent naming conventions** across all files: `vpc-${zone}` for networks, `${namespace}-${service}` for VMs.
- **Extensive use of `for_each`** for VLAN networks, node configs, and team iterations — avoids index-based `count` pitfalls.
- **Provider version pinning** is well-managed: `~> 1.7` for harvester, `~> 13.1` for rancher2, `~> 2.35` for kubernetes. All with `required_version >= 1.5.0`.
- **Variable validation blocks** in `team-template/variables.tf` catch zone mismatches at `terraform plan` time (Layer 1 of the three-layer defence).
- **Good use of `cidrhost()`** for computing static IPs from CIDR blocks — avoids hardcoded IPs.
- **`depends_on` chains** are explicit and correct throughout.
- **Example files** (`.tf.example`) are a good pattern — teams copy what they need without accidentally applying everything.

### Issues Found

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| T1 | **Invalid default subnet values in root `variables.tf`** — defaults include `10.300.0.0/24` and `10.400.0.0/24` (octets > 255). These are syntactically invalid IPs. | **Critical** | `variables.tf:63-74` |
| T2 | **Root-level `cluster_network.tf` creates a ClusterNetwork** — this is a cluster-scoped resource that SRE teams should NOT create. It conflicts with `infra/main.tf`. | High | `cluster_network.tf` |
| T3 | **Root-level files are the original single-team template** but coexist with `team-template/`. The README still references the root-level Quick Start workflow, which is outdated for the multi-team model. | Medium | `README.md`, root `.tf` files |
| T4 | **`rke2_cluster.tf.example` references `harvester_network.vlans["private"]`** but the team-template uses `harvester_network.vpc_vlans["private"]`. Resource name mismatch will cause errors. | **Critical** | `team-template/rke2_cluster.tf.example:86,121` |
| T5 | **`postgresql_ha.tf.example` and `kv_store.tf.example`** reference `harvester_network.vlans["data"]` and `harvester_network.vlans["system"]` — same mismatch as T4. Should be `vpc_vlans`. | **Critical** | `team-template/postgresql_ha.tf.example:175,216`, `team-template/kv_store.tf.example:102` |
| T6 | **`rke2_cluster.tf.example` uses string image reference** (`image = "ubuntu-22.04-server-cloudimg-amd64"`) instead of a Terraform resource reference. This won't work with the Harvester provider — it expects a resource ID. | High | `team-template/rke2_cluster.tf.example:80,115` |
| T7 | **Redis `requirepass ""` is set to empty string** — Redis will accept unauthenticated connections from any allowed network. | Medium | `team-template/kv_store.tf.example:72` |
| T8 | **VyOS cloud-init `network_data` uses `gateway4`** which is deprecated in Netplan v2. Should use `routes` with `to: default via: x.x.x.x`. | Low | `cloudinit.tf:249`, `team-template/cloudinit.tf:249` |
| T9 | **`rke2_cluster.tf.example` cloud-init** uses a generic RKE2 install pattern that may not correctly configure the server vs. agent role for worker nodes. Workers should use `rke2-agent`, not `rke2-server`. | High | `team-template/rke2_cluster.tf.example:57-59` |
| T10 | **No Terraform state backend configured** — all workspaces use local state by default. For a multi-team platform, remote state (S3, Consul, or Terraform Cloud) is essential. | Medium | All `provider.tf` files |
| T11 | **`team-template/outputs.tf` references `harvester_clusternetwork.vpc_trunk`** — but this resource is not created in the team-template workspace (it's created in `infra/`). This will fail. | **Critical** | `team-template/outputs.tf:6-8` |

### Recommendations

1. **T1:** Fix root-level `variables.tf` defaults to use valid subnets (already fixed in `team-template/variables.tf`). Or better yet, remove the root-level `.tf` files entirely since `team-template/` is the canonical version.
2. **T4/T5:** Change `harvester_network.vlans` to `harvester_network.vpc_vlans` in all `.tf.example` files, or rename the resource in `team-template/networks.tf` to match.
3. **T6:** Add an Ubuntu image resource to the team-template or document that teams must upload the image first and reference it by Terraform resource/data source.
4. **T9:** Split the cloud-init into separate configs for control plane (`rke2-server`) and workers (`rke2-agent`).
5. **T10:** Add a commented `backend "s3" {}` block or equivalent in the provider files with documentation on configuring remote state.
6. **T11:** Remove the `cluster_network` output from `team-template/outputs.tf` — it's already in `infra/outputs.tf` where it belongs.

---

## 3. Security Review

### Strengths

- **Three-layer VLAN conflict defence** (Terraform validation → Kyverno admission → audit script) is a robust, defence-in-depth approach.
- **Kyverno policy** is well-crafted with clear error messages, proper preconditions, and two complementary rules (allowlist check + annotation existence check).
- **Namespace-scoped RBAC** with dedicated ServiceAccounts and the `edit` ClusterRole is appropriate. Teams cannot access cluster-scoped resources.
- **Rancher API keys** are marked as `sensitive` in variables.
- **`.gitignore` covers `terraform.tfvars`** and kubeconfig files.
- **Static-host-mapping IPs in reserved range** (.10-.99) with DHCP starting at .100 prevents address conflicts.

### Issues Found

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| S1 | **PostgreSQL `pg_password` is passed in clear text via cloud-init** user_data, which is stored as a Kubernetes Secret but is visible in the Harvester UI and via `kubectl get secret -o yaml`. | High | `team-template/postgresql_ha.tf.example:99-100` |
| S2 | **VyOS SSH listens only on mgmt IP** (good), but **password authentication is not explicitly disabled** in cloud-init. Default VyOS config allows password auth. | Medium | `cloudinit.tf:235-236` |
| S3 | **Redis has no password** (empty `requirepass`). Any pod that can reach port 6379 on the SYSTEM VLAN can read/write data. | Medium | `team-template/kv_store.tf.example:72` |
| S4 | **PostgreSQL replication password** is in cloud-init and visible to anyone who can read the Secret. | Medium | `team-template/postgresql_ha.tf.example:100` |
| S5 | **`ALLOW-INTERNET` rule 20 is overly permissive** — it accepts ALL outbound traffic from all VLANs. No egress filtering. A compromised VM could exfiltrate data or connect to C2 servers. | Medium | `cloudinit.tf:133` |
| S6 | **Nginx proxy VM has `proxy_ssl_verify off`** — this means it doesn't verify the kgateway TLS certificate. Acceptable in a lab but should be properly configured with the internal CA in production. | Low | `deployments/openchoreo/nginx_lb.tf:76` |
| S7 | **`null_resource.copy_nginx_tls`** hardcodes `~/.ssh/id_ed25519` for the private key path. This is not portable and leaks assumptions about the operator's SSH key location. | Low | `deployments/openchoreo/nginx_lb.tf:189` |
| S8 | **No network policy** within the K8s cluster itself. Once pods are on the PRIVATE VLAN, any pod can reach any other pod. Kubernetes NetworkPolicies should be considered. | Low | Gap |

### Recommendations

1. **S1/S4:** Use HashiCorp Vault or Kubernetes ExternalSecrets to inject database passwords rather than embedding them in cloud-init. Document this as a production hardening step.
2. **S2:** Add `set service ssh disable-password-authentication` to VyOS cloud-init.
3. **S3:** Either set a real password for Redis or document that `requirepass` must be set before production use.
4. **S5:** Consider adding egress filtering (allow only ports 80, 443, 53 outbound to specific upstream CIDRs).
5. **S7:** Make the SSH private key path a variable.

---

## 4. Documentation Review

### Strengths

- **AGENT.md is exceptional** — 815 lines covering architecture, VLAN allocation, traffic matrix, RBAC, DNS, troubleshooting, and capacity planning. It serves as both a reference and an onboarding guide.
- **WORKFLOW.md is comprehensive** — phased deployment approach (0→5) with checklists at each phase. Excellent for operational runbooks.
- **Deployment guides** (`deployments/openchoreo.md`, `openchoreo-integrations.md`) are thorough with architecture diagrams, step-by-step instructions, and troubleshooting sections.
- **The OpenChoreo integrations doc** explains every service-to-service connection flow packet-by-packet — rare to see this level of detail in infrastructure repos.
- **Code comments** are extensive and helpful, especially in cloud-init templates and firewall rules.

### Issues Found

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| D1 | **README.md is outdated** — still describes the single-team root-level workflow. Does not mention `infra/`, `team-template/`, or the multi-team model at all. | High | `README.md` |
| D2 | **README traffic matrix is incomplete** — shows PRIVATE→DATA allowing Redis (port 6379) but Redis is in SYSTEM VLAN, not DATA. | Medium | `README.md:23` |
| D3 | **AGENT.md Section 4 directory listing is incomplete** — does not mention `deployments/openchoreo/` Terraform workspace or `deployments/openchoreo-integrations.md`. | Low | `AGENT.md:96-126` |
| D4 | **No CHANGELOG or version history.** Difficult to understand what changed between iterations. | Low | Gap |
| D5 | **`gen-kubeconfig.sh` script is only documented inline** in WORKFLOW.md — not present as an actual file in the repo. | Low | `WORKFLOW.md:372-421` |

### Recommendations

1. **D1:** Rewrite `README.md` to reference the multi-team architecture, link to `AGENT.md` and `WORKFLOW.md`, and remove the outdated single-team Quick Start.
2. **D2:** Fix the traffic matrix in README.md to match the actual firewall rules.
3. **D5:** Create `scripts/gen-kubeconfig.sh` as a standalone script rather than embedding it in documentation.

---

## 5. Operational Readiness

### What Works Well

- **Audit script** (`scripts/audit-vlans.sh`) is well-written with colour-coded output, three distinct checks, and a non-zero exit code for CI integration.
- **Phase-based workflow** in WORKFLOW.md provides clear ordering guarantees.
- **Team offboarding process** is documented with the important note to never reuse VLAN offsets.
- **Troubleshooting guides** cover the most common failure modes with step-by-step diagnosis.

### Gaps

| # | Gap | Severity |
|---|-----|----------|
| O1 | **No monitoring/alerting** for VyOS router health, DHCP pool exhaustion, or firewall rule hit counts. | Medium |
| O2 | **No automated testing** — no CI pipeline, no `terraform validate`/`plan` in CI, no integration tests. | Medium |
| O3 | **No disaster recovery procedure** for restoring a team VPC after a VyOS VM failure. | Medium |
| O4 | **`files-5.zip`** is committed to the repo — appears to be an archive that should not be in version control. `.gitignore` has `*.zip` but this file was committed before the rule was added. | Low |
| O5 | **VyOS image URL points to a nightly rolling build** (`1.5-rolling-202402120023`). This is not a stable release and could disappear from GitHub. | Medium |

### Recommendations

1. **O1:** Add a simple health check script or CronJob that pings VyOS management IPs and checks DHCP pool utilisation.
2. **O2:** Add a CI pipeline (GitHub Actions) that runs `terraform fmt -check`, `terraform validate`, and `terraform plan` (with a mock backend) on PRs.
3. **O4:** Remove `files-5.zip` from the repo with `git rm files-5.zip`.
4. **O5:** Pin the VyOS image to a stable release or mirror it to an internal registry.

---

## 6. OpenChoreo Deployment Workspace Review

### Strengths

- **Fully automated via Terraform** — the `deployments/openchoreo/` workspace automates everything from Nginx proxy VM creation to Helm chart installation.
- **Two-stage apply pattern** is well-documented and handles the Thunder→OIDC→CP chicken-and-egg dependency correctly.
- **All secrets are managed via `kubernetes_secret_v1`** resources — not hardcoded in Helm values.
- **Proper dependency chains** (`depends_on`) ensure resources are created in the correct order.
- **Outputs include a post-deployment checklist** with copy-pastable commands.

### Issues Found

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| C1 | **`helm_release.cert_manager` uses `oci://quay.io/jetstack`** but the deployment guide references `oci://ghcr.io/cert-manager/charts/cert-manager`. These are different registries. | Medium | `deployments/openchoreo/choreo_prereqs.tf:43-44` vs `deployments/openchoreo.md:388-389` |
| C2 | **`openchoreo_cp.tf` has duplicate `backstage` and `kgateway` keys** in the YAML values block — `backstage` appears twice (once for database config, once for resources), and `kgateway` appears twice (once for service config, once for resources). YAML does not allow duplicate keys — the second occurrence silently overwrites the first. | **Critical** | `deployments/openchoreo/openchoreo_cp.tf:47-114` |
| C3 | **OpenChoreo version pinned to `0.16.0`** — should be parameterised per-chart rather than using a single version for thunder, openchoreo, and data-plane (they may diverge). | Low | `deployments/openchoreo/variables.tf:160-163` |

### Recommendations

1. **C2:** Merge the duplicate YAML keys into single blocks. For example, combine the `backstage.database` and `backstage.resources` sections under one `backstage:` key.
2. **C1:** Align the cert-manager registry between Terraform code and documentation.

---

## 7. Code Duplication Analysis

The root-level `.tf` files and `team-template/` files are largely identical, with the team-template being the improved version. This duplication can cause confusion.

| Root file | Team-template equivalent | Differences |
|-----------|--------------------------|-------------|
| `variables.tf` | `team-template/variables.tf` | Root has invalid subnet defaults, missing validation blocks, missing `dns_domain` default |
| `cloudinit.tf` | `team-template/cloudinit.tf` | Identical content |
| `networks.tf` | `team-template/networks.tf` | Root references `harvester_clusternetwork.vpc_trunk.name`, team-template uses `var.cluster_network_name` |
| `vyos_router.tf` | `team-template/vyos_router.tf` | Identical content |
| `images.tf` | `team-template/images.tf` | Identical content |
| `outputs.tf` | `team-template/outputs.tf` | Root references `harvester_clusternetwork.vpc_trunk` (exists), team-template references same (doesn't exist in scope) |
| `provider.tf` | `team-template/provider.tf` | Team-template adds `rancher2` provider |
| `cluster_network.tf` | (managed by `infra/main.tf`) | Root creates a cluster-scoped resource that teams shouldn't create |

**Recommendation:** Consider removing or clearly marking the root-level `.tf` files as deprecated/legacy. The canonical template is `team-template/`, and the shared infrastructure is in `infra/`. The root files serve no purpose in the current multi-team architecture and actively introduce confusion.

---

## 8. Summary of Findings by Severity

### Critical (must fix before production use)

| # | Finding |
|---|---------|
| T1 | Invalid default subnet values in root `variables.tf` (10.300.x, 10.400.x) |
| T4 | `rke2_cluster.tf.example` references wrong resource name (`vlans` vs `vpc_vlans`) |
| T5 | `postgresql_ha.tf.example` and `kv_store.tf.example` same resource name mismatch |
| T11 | `team-template/outputs.tf` references `harvester_clusternetwork.vpc_trunk` which doesn't exist in scope |
| C2 | Duplicate YAML keys in `openchoreo_cp.tf` Helm values — silent data loss |

### High (should fix soon)

| # | Finding |
|---|---------|
| T2 | Root-level `cluster_network.tf` creates cluster-scoped resources (conflicts with `infra/`) |
| T6 | `.tf.example` files use string image references instead of Terraform resource IDs |
| T9 | RKE2 worker nodes use `rke2-server` instead of `rke2-agent` |
| S1 | PostgreSQL passwords visible in cloud-init Secrets |
| D1 | README.md is outdated — doesn't describe the multi-team architecture |

### Medium (should fix before production)

| # | Finding |
|---|---------|
| A1 | VyOS router is a single point of failure per team |
| A2 | No backup/restore strategy documented |
| T3 | Root-level files coexist with team-template causing confusion |
| T7 | Redis has no authentication configured |
| T10 | No remote state backend configured |
| S2 | VyOS SSH password auth not explicitly disabled |
| S3 | Redis `requirepass` is empty |
| S5 | Overly permissive outbound firewall rules |
| O1-O3 | No monitoring, no CI, no DR procedure |
| O5 | VyOS image is a nightly rolling build |
| C1 | cert-manager registry mismatch between code and docs |
| D2 | README traffic matrix incorrectly places Redis in DATA VLAN |

### Low (nice to have)

| # | Finding |
|---|---------|
| A3 | 10-team scalability ceiling with current VLAN offset scheme |
| T8 | Deprecated `gateway4` in Netplan network_data |
| S6-S8 | Various minor security hardening items |
| D3-D5 | Minor documentation gaps |
| O4 | `files-5.zip` committed to repo |
| C3 | Single version variable for all OpenChoreo charts |

---

## 9. Positive Highlights

These aspects are particularly well done and worth preserving:

1. **The three-layer VLAN conflict defence** (validation → admission → audit) is a textbook defence-in-depth implementation.
2. **The `extra_service_dns` variable design** is elegant — it allows arbitrary application DNS entries without modifying the core cloud-init template.
3. **The OpenChoreo deployment workspace** demonstrates how to extend the platform for real applications — it's a great reference architecture.
4. **The `openchoreo-integrations.md` document** is exceptional — packet-level request flow documentation is rare and invaluable for troubleshooting.
5. **The phased WORKFLOW.md** with checklists at each phase is a model for operational runbooks.
6. **The VLAN calculator** in AGENT.md makes it trivial for anyone to compute a new team's allocation.
7. **IP reservation design** (`.10-.99` static, `.100+` DHCP) is simple and collision-free.

---

## 10. Conclusion

This repository represents a solid, well-thought-out infrastructure platform. The architecture is sound, the documentation is among the best I've seen for infrastructure repos, and the operational tooling (audit script, phased workflows, checklists) shows maturity.

The critical issues (T1, T4, T5, T11, C2) are all straightforward fixes — mostly resource name mismatches between the template files and their example counterparts. Once addressed, along with the security hardening items (S1-S5), this platform would be ready for production use.

The biggest strategic recommendation is to **deprecate or remove the root-level `.tf` files** in favour of the `team-template/` and `infra/` structure. This would eliminate an entire class of confusion and bugs.
