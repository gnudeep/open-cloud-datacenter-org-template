# Repository Review Report

**Repository:** lk-dc-org-template
**Reviewed by:** Claude Opus (1M context)
**Date:** 2026-03-01 (third review)
**Scope:** Full repository — architecture, Terraform code, documentation, security, and operational readiness
**Revision note:** Third pass. Many issues from earlier reviews have been fixed in recent commits (`bc8e414`, `b45878a`, `1e4508e`). This revision verifies every finding against the **current** codebase and removes all resolved items. Remaining issues are genuine.

---

## Executive Summary

This repository implements a **multi-team VPC-like network isolation platform** on Harvester HCI 1.7.1 using VyOS router VMs and VLAN segmentation. It is well-architected, thoroughly documented, and demonstrates mature infrastructure-as-code practices. The two-layer model (platform `infra/` vs team `team-template/`) cleanly separates concerns and enables safe multi-tenancy on shared bare-metal infrastructure.

Since the prior review, the maintainers have addressed the majority of critical and high-severity findings, including: fixing invalid subnet defaults, correcting the RKE2 example to separate server/agent roles, adding image data sources, fixing Redis authentication, disabling VyOS SSH password auth, upgrading PostgreSQL to `scram-sha-256`, rewriting the README, and aligning cert-manager registries.

**Overall assessment: Production-ready with minor caveats.** The remaining issues are predominantly architectural considerations, operational tooling gaps, and low-severity hardening items.

**Rating: 9.0/10** (up from 8.5 in prior review)

---

## 1. Architecture Review

### Strengths

- **Clean two-layer separation.** The `infra/` module handles cluster-scoped resources (ClusterNetwork, VLANConfig, Namespaces, RBAC) while `team-template/` is namespace-scoped. This maps directly to the trust boundary — platform admins vs. SRE teams.
- **Deterministic VLAN allocation formula.** The `100+(N-1)*10` formula for VLAN IDs and `10.N.x.0/24` for subnets is simple, predictable, and well-documented. It avoids the need for a separate IPAM system.
- **VyOS as a per-team router** provides strong L2/L3 isolation between teams without requiring physical switch ACLs per team. Each team owns their firewall policy.
- **Four-zone model** (public/private/system/data) maps cleanly to a standard three-tier application architecture plus a dedicated data tier.
- **DNS design is elegant.** The two-layer approach (VyOS dnsmasq for VM-level DNS + CoreDNS stub zone for K8s pod access) provides seamless service discovery without extra infrastructure.
- **Static IP reservation scheme** (`.10-.99` for named services, `.100-.200` for DHCP) is simple, collision-free, and well-documented.

### Concerns

| # | Concern | Severity | Location |
|---|---------|----------|----------|
| A1 | **Single VyOS router per team = SPOF.** No HA for the VyOS router VM. If it goes down, the entire team VPC loses routing, NAT, DHCP, and DNS. VyOS on KubeVirt does support `LiveMigrate` eviction, but there's no VRRP pair or failover documented. | Medium | `team-template/vyos_router.tf` |
| A2 | **No backup/restore strategy** documented for VyOS configuration or PostgreSQL data. A `terraform apply` would recreate the VyOS VM with the same config, but DHCP lease state and any manual VyOS changes would be lost. | Medium | Documentation gap |
| A3 | **Scalability ceiling at 10 teams** with 10-step VLAN offsets (100,110,...,190). Documented in AGENT.md Section 11 (with a mitigation to use 5-step offsets for 20 teams), but easy to overlook during rapid team onboarding. | Low | `AGENT.md` Section 11 |

### Recommendations

1. **A1:** Document VyOS HA options (VRRP pair, or KubeVirt VM live migration via `LiveMigrate` eviction strategy) as a production hardening step.
2. **A2:** Add a `backups/` section to documentation covering VyOS config export (`show configuration commands > backup.txt`), note that `terraform apply` is the primary recovery mechanism, and document PostgreSQL backup scheduling (`pg_basebackup` or `pg_dump` cron).

---

## 2. Terraform Code Quality

### Strengths

- **Consistent naming conventions** across all files: `vpc-${zone}` for networks, `${namespace}-${service}` for VMs, `${team}-deployer` for ServiceAccounts.
- **Extensive use of `for_each`** for VLAN networks, node configs, and team iterations — avoids index-based `count` pitfalls.
- **Provider version pinning** is well-managed: `~> 1.7` for harvester, `~> 13.1` for rancher2, `~> 2.35` for kubernetes. All with `required_version >= 1.5.0`.
- **Variable validation blocks** in `team-template/variables.tf` catch zone mismatches at `terraform plan` time — five validation rules covering VLAN ranges, CIDR uniqueness, and required zone keys.
- **Good use of `cidrhost()`** for computing static IPs from CIDR blocks — avoids hardcoded IPs throughout.
- **`depends_on` chains** are explicit and correct throughout.
- **Example files** (`.tf.example`) pattern is well-executed — teams copy what they need without accidentally applying everything.
- **Resource naming in `team-template/` is consistent** — all `.tf.example` files correctly reference `harvester_network.vpc_vlans["zone"]` matching `networks.tf`.
- **Ubuntu image data source** (`data "harvester_image" "ubuntu"`) in `images.tf` is correctly referenced by all example files via `data.harvester_image.ubuntu.id`.
- **RKE2 example** correctly separates control-plane (`rke2-server`) and worker (`rke2-agent`) cloud-init with proper join configuration via `coalesce(var.rke2_cp_ip, local.rke2_cp_ip):9345`.
- **`rke2_provider.tf.example`** consolidates the Kubernetes provider for RKE2, preventing duplicate provider declarations when multiple example files are used together.
- **Redis authentication** is now a required sensitive variable (`var.redis_password`), not an empty string.

### Remaining Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| T1 | **Root-level `cluster_network.tf` creates a ClusterNetwork** — this is a cluster-scoped resource that SRE teams should NOT create. It conflicts with `infra/main.tf` which also creates this resource. The README correctly notes root files are the "original single-team baseline" but they remain functional Terraform that could be accidentally applied. | Medium | `cluster_network.tf` |
| T2 | **Root-level files coexist with `team-template/`**, creating a potential confusion vector. Although the README now documents that root files are the legacy baseline, they could be accidentally `terraform apply`'d by a new team member. | Low | Root `.tf` files |
| T3 | **VyOS cloud-init `network_data` uses deprecated `gateway4`** in several files. Netplan v2 deprecates `gateway4` in favour of `routes: [{to: default, via: x.x.x.x}]`. The RKE2 example has been updated but other files still use the old syntax. | Low | `cloudinit.tf:246`, `team-template/cloudinit.tf:246`, `team-template/postgresql_ha.tf.example:66,119`, `team-template/kv_store.tf.example:49`, `deployments/openchoreo/nginx_lb.tf:117` |
| T4 | **No Terraform state backend configured** — all workspaces use local state by default. For a multi-team platform where multiple operators may run Terraform, remote state (S3, Consul, or Terraform Cloud) is recommended to prevent state conflicts and enable collaboration. | Medium | All `provider.tf` files |
| T5 | **Consul Option B still uses deprecated `gateway4`** in network_data. | Low | `team-template/kv_store.tf.example:140` |

### Recommendations

1. **T1/T2:** Consider adding a `_DEPRECATED.md` file in the root directory, or moving root-level `.tf` files into a `legacy/` subdirectory, to make the deprecation more visible.
2. **T3/T5:** Update remaining `gateway4` references to `routes: [{to: default, via: ...}]` for consistency with the RKE2 example which already uses the new syntax.
3. **T4:** Add a commented `backend "s3" {}` block or equivalent in the provider files with documentation on configuring remote state.

---

## 3. Security Review

### Strengths

- **Three-layer VLAN conflict defence** (Terraform validation → Kyverno admission → audit script) is a robust, defence-in-depth approach.
- **Kyverno policy** is well-crafted with clear error messages, proper preconditions, and two complementary rules (allowlist check + annotation existence check).
- **Namespace-scoped RBAC** with dedicated ServiceAccounts and the `edit` ClusterRole. Custom `harvester-namespace-user` ClusterRole properly scopes Harvester CRD access.
- **Rancher API keys** are marked as `sensitive` in variables.
- **`.gitignore` covers `terraform.tfvars`**, kubeconfig files, and `*.zip` archives.
- **VyOS SSH password authentication is disabled** — `set service ssh disable-password-authentication` is present in both `cloudinit.tf` files.
- **Redis requires authentication** — `requirepass` uses `var.redis_password` (sensitive, no default).
- **PostgreSQL uses `scram-sha-256`** for authentication — the stronger hash algorithm replacing the old `md5`.
- **Namespace annotations** (`platform/allowed-vlans`) are the single source of truth for VLAN enforcement, set by platform team with no SRE team PATCH access.

### Remaining Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| S1 | **PostgreSQL passwords are passed via cloud-init** user_data, which is stored as a Kubernetes Secret. The Secret is base64-encoded (not encrypted) and visible via `kubectl get secret -o yaml` and in the Harvester UI. While there's no alternative for VM-based deployments without a secrets agent, this should be documented as a known limitation. | Medium | `team-template/postgresql_ha.tf.example:99-100` |
| S2 | **`ALLOW-INTERNET` rule 20 is overly permissive** — it accepts ALL outbound traffic from all VLANs with no protocol, port, or destination restrictions. A compromised VM could exfiltrate data to any destination. | Medium | `cloudinit.tf:133`, `team-template/cloudinit.tf:133` |
| S3 | **Nginx proxy VM has `proxy_ssl_verify off`** — does not verify the kgateway TLS certificate. Acceptable in a lab but should be configured with the internal CA certificate in production. | Low | `deployments/openchoreo/nginx_lb.tf:76` |
| S4 | **No Kubernetes NetworkPolicy** within the RKE2 cluster. Once pods are on the PRIVATE VLAN, any pod can communicate with any other pod on any port. Standard K8s behaviour but worth considering for production hardening. | Low | Gap |

### Recommendations

1. **S1:** Document this as a known limitation in the PostgreSQL example file header. For production, recommend deploying a Vault agent or cloud-init secret injection mechanism.
2. **S2:** Consider adding egress filtering — at minimum, restrict outbound to ports 80, 443, 53 (DNS), and 123 (NTP). A fully open egress path is a significant risk vector.

---

## 4. Documentation Review

### Strengths

- **README.md is now excellent** — properly describes the multi-team architecture, directs readers to the correct entry point based on their role, includes the repo structure, architecture diagram, VLAN allocation table, traffic matrix, quick start for both platform and SRE teams, and links to AGENT.md and WORKFLOW.md. The root-level `.tf` files are clearly marked as the legacy baseline.
- **AGENT.md is exceptional** — 815 lines covering architecture, VLAN allocation, traffic matrix, RBAC, DNS, troubleshooting, and capacity planning.
- **WORKFLOW.md is comprehensive** — phased deployment approach (0→5) with checklists at each phase. The two-role distinction (`[PLATFORM]` vs `[SRE]`) makes responsibilities clear.
- **Deployment guides** (`deployments/openchoreo.md`, `openchoreo-integrations.md`) are thorough with architecture diagrams, step-by-step instructions, and troubleshooting sections.
- **The OpenChoreo integrations doc** explains every service-to-service connection flow packet-by-packet — invaluable for troubleshooting.
- **Traffic matrix in README** is now correct — Redis (6379) is shown under PRIVATE→SYSTEM, PostgreSQL (5432) and Kafka (9092) under PRIVATE→DATA.
- **`scripts/gen-kubeconfig.sh`** now exists as a standalone executable script.

### Remaining Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| D1 | **AGENT.md Section 4 directory listing is incomplete** — does not mention `deployments/openchoreo/` Terraform workspace, `deployments/openchoreo-integrations.md`, `scripts/gen-kubeconfig.sh`, or `rke2_provider.tf.example`. | Low | `AGENT.md:96-126` |
| D2 | **No CHANGELOG or version history.** Given the rapid evolution (fixes from review reports), a CHANGELOG would help operators understand what changed and when. | Low | Gap |

---

## 5. Operational Readiness

### What Works Well

- **Audit script** (`scripts/audit-vlans.sh`) is production-quality: `set -euo pipefail`, argument parsing, dependency checks, colour-coded output, three distinct checks, and CI-friendly exit codes.
- **`gen-kubeconfig.sh`** is now a standalone script in `scripts/` with proper argument validation.
- **Phase-based workflow** in WORKFLOW.md provides clear ordering guarantees and checklists.
- **Team offboarding process** is documented with the critical note to never reuse VLAN offsets.
- **Troubleshooting guides** cover the most common failure modes.
- **Deployment ordering** is clearly documented: infra → team VPC → RKE2 → PostgreSQL → KV Store.
- **`files-5.zip`** has been removed from git tracking (now gitignored).

### Remaining Gaps

| # | Gap | Severity |
|---|-----|----------|
| O1 | **No monitoring/alerting** for VyOS router health, DHCP pool exhaustion, firewall rule hit counts, or VM resource utilisation. A single dropped VyOS VM would silently take down an entire team's VPC. | Medium |
| O2 | **No automated CI pipeline** — no `terraform fmt -check`, `terraform validate`, or `terraform plan` runs on PRs. Given this repo has three distinct Terraform workspaces, CI would catch regressions. | Medium |
| O3 | **No disaster recovery procedure** documented for restoring a team VPC after a VyOS VM failure. While `terraform apply` would recreate it, DHCP lease state and any manual VyOS changes would be lost. | Low |
| O4 | **VyOS image URL points to a nightly rolling build** (`1.5-rolling-202402120023` from Feb 2024). This is not a stable release, could disappear from GitHub, and is over 2 years old. | Medium |

### Recommendations

1. **O1:** Add a simple health check script that pings VyOS management IPs and checks DHCP pool utilisation, suitable for CronJob or Prometheus pushgateway.
2. **O2:** Add a GitHub Actions pipeline that runs `terraform fmt -check` and `terraform validate` for each workspace on PRs.
3. **O4:** Pin the VyOS image to a stable LTS release or mirror it to an internal artifact registry.

---

## 6. OpenChoreo Deployment Workspace Review

### Strengths

- **Fully automated via Terraform** — automates everything from Nginx proxy VM creation to Helm chart installation, including Gateway API CRDs, cert-manager (with aligned registries), and the internal CA chain.
- **Two-stage apply pattern** is well-documented and correctly handles the Thunder→OIDC→Control Plane dependency.
- **All secrets are managed via `kubernetes_secret_v1`** resources — not hardcoded in Helm values.
- **Proper dependency chains** (`depends_on`) ensure correct ordering, including a `null_resource.wait_for_thunder` that polls OIDC discovery.
- **Outputs include a post-deployment checklist** with copy-pastable commands.
- **Internal CA chain** is properly set up: self-signed root → CA Certificate → CA ClusterIssuer.
- **SSH private key path** is now a variable (`var.ssh_private_key_path`) with `pathexpand()`.
- **cert-manager registry** is now aligned between Terraform code and documentation (`oci://ghcr.io/cert-manager/charts`).

### Remaining Issues

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| C1 | **Potential conflict with team-workspace `service_dns.tf`.** If both `choreo_k8s_services.tf` (OpenChoreo workspace) and `service_dns.tf` (team workspace) are applied, the `postgres` and `postgres-ro` K8s Services will conflict. The file header documents this warning, but there is no programmatic guard (e.g., a `create_postgres_service` boolean variable). | Medium | `deployments/openchoreo/choreo_k8s_services.tf:18-19` |
| C2 | **OpenChoreo version is a single variable** (`openchoreo_version`) used for thunder, openchoreo, and data-plane charts. If these charts release on different cadences, independent upgrades would require per-chart variables. | Low | `deployments/openchoreo/variables.tf:160-163` |
| C3 | **`null_resource.copy_nginx_tls` uses SSH `remote-exec`** which requires the Nginx VM to be directly reachable from the Terraform operator's machine. In some topologies this will fail. | Low | `deployments/openchoreo/nginx_lb.tf:168-234` |

### Recommendations

1. **C1:** Add a `create_db_services = true` variable to `choreo_k8s_services.tf` with a `count` guard on the Service/Endpoints resources, allowing operators to skip them if `service_dns.tf` is already applied.

---

## 7. Code Duplication Analysis

The root-level `.tf` files and `team-template/` files share significant code. The root files are now documented as the "original single-team baseline" in the README, but still exist as functional Terraform.

| Root file | Team-template equivalent | Key differences |
|-----------|--------------------------|-----------------|
| `variables.tf` | `team-template/variables.tf` | Root now has valid defaults (`10.1.x.0/24`) but still lacks validation blocks and some variables (`redis_password`, `ubuntu_image_name`, `rancher_*`). |
| `cloudinit.tf` | `team-template/cloudinit.tf` | Identical content (both updated with password-auth disable, correct firewall rules). |
| `networks.tf` | `team-template/networks.tf` | Root references `harvester_clusternetwork.vpc_trunk.name` (resource); team-template uses `var.cluster_network_name` (variable) — the team-template approach is correct for namespace-scoped operation. |
| `vyos_router.tf` | `team-template/vyos_router.tf` | Identical content. |
| `images.tf` | `team-template/images.tf` | Root only has VyOS image resource; team-template also has Ubuntu image data source + `ubuntu_image_name` variable. |
| `outputs.tf` | `team-template/outputs.tf` | Root references `harvester_clusternetwork.vpc_trunk` (resource in scope); team-template correctly uses `var.cluster_network_name`. |
| `provider.tf` | `team-template/provider.tf` | Root has only `harvester`; team-template adds `rancher2` provider. |
| `cluster_network.tf` | (managed by `infra/main.tf`) | Root creates cluster-scoped ClusterNetwork + VLANConfig — should only be done by platform team. |

**Assessment:** The root-level files now have valid defaults and updated firewall rules, but they still create cluster-scoped resources (`cluster_network.tf`) and lack the variable validation, Ubuntu image data source, and Rancher provider that `team-template/` provides. The README correctly documents them as legacy, which is an acceptable approach.

---

## 8. Summary of Findings by Severity

### Critical

None. All previously identified critical issues have been resolved.

### High

None. All previously identified high-severity issues have been resolved.

### Medium (should address before production)

| # | Finding | Status |
|---|---------|--------|
| A1 | VyOS router is a single point of failure per team | Open — architectural, needs documentation |
| A2 | No backup/restore strategy documented | Open |
| T1 | Root-level `cluster_network.tf` creates cluster-scoped resources (conflict risk with `infra/`) | Open — mitigated by README warning |
| T4 | No remote state backend configured for any workspace | Open |
| S1 | PostgreSQL passwords visible in cloud-init Secrets (inherent to VM-based secrets) | Open — needs documentation |
| S2 | Overly permissive outbound firewall rules (`ALLOW-INTERNET` rule 20 accepts all) | Open |
| O1 | No monitoring/alerting for VyOS or infrastructure health | Open |
| O2 | No CI pipeline for Terraform validation | Open |
| O4 | VyOS image is a 2-year-old nightly rolling build | Open |
| C1 | Potential K8s Service conflict between OpenChoreo and team workspaces | Open |

### Low (nice to have)

| # | Finding | Status |
|---|---------|--------|
| A3 | 10-team scalability ceiling with current VLAN offset scheme | Open — documented |
| T2 | Root-level files coexist with team-template (legacy, now documented) | Open — mitigated |
| T3 | Deprecated `gateway4` in several cloud-init `network_data` blocks | Open |
| S3 | Nginx `proxy_ssl_verify off` in OpenChoreo deployment | Open |
| S4 | No Kubernetes NetworkPolicy within the RKE2 cluster | Open |
| D1 | AGENT.md directory listing slightly incomplete | Open |
| D2 | No CHANGELOG | Open |
| O3 | No disaster recovery procedure documented | Open |
| C2 | Single version variable for all OpenChoreo charts | Open |
| C3 | SSH remote-exec provisioner requires direct network access to Nginx VM | Open |

---

## 9. Positive Highlights

These aspects are particularly well done and worth preserving:

1. **The three-layer VLAN conflict defence** (Terraform validation → Kyverno admission webhook → audit script) is a textbook defence-in-depth implementation. Each layer catches different failure modes with clear remediation instructions.
2. **The `extra_service_dns` variable design** is elegant — allows arbitrary application DNS entries via a simple `map(string)` without modifying the core cloud-init template.
3. **The OpenChoreo deployment workspace** is a complete, production-grade reference architecture with proper secret management, dependency ordering, and a two-stage apply pattern.
4. **The `openchoreo-integrations.md` document** provides packet-level request flow documentation from browser to pod, through every VyOS ruleset, with numbered steps — invaluable for troubleshooting.
5. **The phased WORKFLOW.md** with checklists at each phase (0→5) is a model for operational runbooks. The `[PLATFORM]` vs `[SRE]` role distinction makes responsibilities crystal clear.
6. **The VLAN calculator** in AGENT.md makes it trivial for anyone to compute a new team's allocation.
7. **IP reservation design** (`.10-.99` for static services, `.100-.200` for DHCP) creates DNS records before VMs exist — zero-config service discovery.
8. **The audit script** (`scripts/audit-vlans.sh`) is production-quality: `set -euo pipefail`, argument parsing, dependency checks, colour-coded output, and CI-friendly exit codes.
9. **Namespace annotation design** — `platform/allowed-vlans` as the single source of truth for both Kyverno and the audit script, with platform-only write access, is a clean authorization model.
10. **The README rewrite** is now an exemplary entry point — role-based navigation table, clear repo structure, correct traffic matrix, quick-start for both audiences, and proper links to detailed docs.

---

## 10. Issues Resolved Since Prior Reviews

The following issues from earlier review iterations have been verified as **fixed** in the current codebase:

| Prior # | Issue | How it was resolved |
|---------|-------|---------------------|
| T1 (old) | Invalid subnet defaults `10.300.0.0/24`, `10.400.0.0/24` in root `variables.tf` | Fixed: now uses valid `10.1.x.0/24` subnets |
| T4/T5 (old) | `.tf.example` files used string image references | Fixed: all now use `data.harvester_image.ubuntu.id` |
| T7 (old) | Consul Option B hostname set to `redis` instead of `consul` | Fixed: now uses `hostname: consul`, `fqdn: consul.${var.dns_domain}` |
| T8/T9 (old) | Duplicate `provider "kubernetes"` and variable definitions across example files | Fixed: consolidated into `rke2_provider.tf.example` |
| T10 (old) | RKE2 workers used `rke2-server` instead of `rke2-agent` | Fixed: separate cloud-init secrets — CP uses `rke2-server`, workers use `rke2-agent` with `INSTALL_RKE2_TYPE="agent"` |
| T11 (old) | RKE2 `config.yaml` used `manifest_url` for `server:` field | Fixed: workers use `https://${coalesce(var.rke2_cp_ip, local.rke2_cp_ip)}:9345`; CP omits `server:` (correct for primary) |
| T14 (old) | `PRIV-TO-DATA` rule 30 opened Redis 6379 on DATA VLAN | Fixed: rule 30 is now Kafka (9092); Redis is only in `PRIV-TO-SYS` rule 40 |
| S2 (old) | VyOS SSH password auth not disabled | Fixed: `set service ssh disable-password-authentication` added |
| S3/T6 (old) | Redis `requirepass ""` (empty) | Fixed: uses `var.redis_password` (sensitive, required) |
| S7 (old) | Hardcoded `~/.ssh/id_ed25519` in nginx TLS provisioner | Fixed: now `var.ssh_private_key_path` with `pathexpand()` |
| S9 (old) | PostgreSQL used `md5` auth | Fixed: now uses `scram-sha-256` throughout `pg_hba.conf` |
| D1 (old) | README.md outdated — single-team only | Fixed: complete rewrite with multi-team architecture, role-based navigation, correct traffic matrix |
| D2/D3 (old) | Traffic matrix incorrect/inconsistent | Fixed: README and firewall rules now align with AGENT.md architecture |
| D6 (old) | `gen-kubeconfig.sh` only inline in docs | Fixed: now exists as `scripts/gen-kubeconfig.sh` |
| D7 (old) | README said "Terraform >= 1.0" | Fixed: now says "Terraform >= 1.5.0" |
| C1 (old) | cert-manager registry mismatch | Fixed: both Terraform and docs use `oci://ghcr.io/cert-manager/charts` |
| O4 (old) | `files-5.zip` tracked by git | Fixed: removed from git tracking, now gitignored |

---

## 11. Conclusion

This repository has improved significantly since the initial review. The maintainers have addressed **all critical and high-severity issues** identified in prior reviews, demonstrating strong responsiveness and code quality commitment.

The remaining medium-severity items fall into three categories:

1. **Architectural considerations** (VyOS SPOF, no backup strategy) — inherent to the design, best addressed through documentation and optional HA patterns.
2. **Operational tooling gaps** (no monitoring, no CI, old VyOS image) — important for production but don't affect correctness.
3. **Security hardening** (permissive egress rules, cloud-init secrets) — typical for infrastructure repos at this stage; the security posture is already well above average with the three-layer VLAN defence and proper RBAC.

**The platform is production-ready** for organisations that:
- Accept VyOS as a single point of failure per team (with `terraform apply` as the recovery mechanism)
- Add monitoring for VyOS health out-of-band
- Pin the VyOS image to a stable release before deploying

The documentation quality (README, AGENT.md, WORKFLOW.md, deployment guides, integration reference) is outstanding and sets a high bar for infrastructure-as-code repositories.
