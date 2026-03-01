# Repository Review Report

**Repository:** lk-dc-org-template
**Reviewed by:** Claude Opus (1M context)
**Date:** 2026-03-01 (revised)
**Scope:** Full repository — architecture, Terraform code, documentation, security, and operational readiness
**Revision note:** This is a corrected revision. The initial report contained several false positives (T4, T5, T11, C2) which have been removed. New findings have been added after deeper verification.

---

## Executive Summary

This repository implements a **multi-team VPC-like network isolation platform** on Harvester HCI 1.7.1 using VyOS router VMs and VLAN segmentation. It is well-architected, thoroughly documented, and demonstrates mature infrastructure-as-code practices. The two-layer model (platform `infra/` vs team `team-template/`) cleanly separates concerns and enables safe multi-tenancy on shared bare-metal infrastructure.

**Overall assessment: Production-ready for lab/staging environments.** Issues exist primarily in the root-level legacy files, firewall rule inconsistencies, and security hardening gaps. The `team-template/` and `infra/` code is solid.

**Rating: 8.5/10**

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
| A1 | **Single VyOS router per team = SPOF.** No HA for the VyOS router VM. If it goes down, the entire team VPC loses routing, NAT, DHCP, and DNS. | Medium | `team-template/vyos_router.tf` |
| A2 | **No backup/restore strategy** documented for VyOS configuration or PostgreSQL data. | Medium | Documentation gap |
| A3 | **Scalability ceiling at 10 teams** with 10-step VLAN offsets (100,110,...,190). Documented in AGENT.md Section 11 but easy to overlook during rapid team onboarding. | Low | `AGENT.md` Section 11 |
| A4 | **Cross-team traffic is "blocked by default" only at L2** — there is no explicit VyOS deny rule between team subnets (e.g., 10.1.0.0/22 cannot route to 10.2.0.0/22). Since each VyOS only knows its own subnets, this isolation depends on the upstream gateway not routing between VPCs. | Low | `cloudinit.tf` |

### Recommendations

1. **A1:** Document VyOS HA options (VRRP pair, or KubeVirt VM live migration via `LiveMigrate` eviction strategy) for production use.
2. **A2:** Add a `backups/` section to documentation covering VyOS config export (`show configuration commands > backup.txt`) and PostgreSQL `pg_basebackup` scheduling.
3. **A4:** Consider adding explicit deny rules in VyOS for other team subnets if the upstream gateway could theoretically route between them.

---

## 2. Terraform Code Quality

### Strengths

- **Consistent naming conventions** across all files: `vpc-${zone}` for networks, `${namespace}-${service}` for VMs, `${team}-deployer` for ServiceAccounts.
- **Extensive use of `for_each`** for VLAN networks, node configs, and team iterations — avoids index-based `count` pitfalls.
- **Provider version pinning** is well-managed: `~> 1.7` for harvester, `~> 13.1` for rancher2, `~> 2.35` for kubernetes. All with `required_version >= 1.5.0`.
- **Variable validation blocks** in `team-template/variables.tf` catch zone mismatches at `terraform plan` time — five validation rules covering VLAN ranges, CIDR uniqueness, and required zone keys.
- **Good use of `cidrhost()`** for computing static IPs from CIDR blocks — avoids hardcoded IPs throughout.
- **`depends_on` chains** are explicit and correct throughout.
- **Example files** (`.tf.example`) are a good pattern — teams copy what they need without accidentally applying everything.
- **Resource naming in `team-template/` is consistent** — all `.tf.example` files correctly reference `harvester_network.vpc_vlans["zone"]` matching the resource name in `networks.tf`.

### Issues Found

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| T1 | **Invalid default subnet values in root `variables.tf`** — defaults include `10.300.0.0/24` and `10.400.0.0/24` (octets > 255). These are syntactically invalid IPs and will cause Terraform to fail. The same invalid values appear in root `terraform.tfvars.example`. | **Critical** | `variables.tf:63-74`, `terraform.tfvars.example:38-49` |
| T2 | **Root-level `cluster_network.tf` creates a ClusterNetwork** — this is a cluster-scoped resource that SRE teams should NOT create. It conflicts with `infra/main.tf` which also creates this resource. Running both would cause a naming collision. | High | `cluster_network.tf` |
| T3 | **Root-level files are the original single-team template** but coexist with `team-template/`. This creates confusion about which is canonical and risks teams using the wrong (buggy) root-level files. | Medium | Root `.tf` files |
| T4 | **`rke2_cluster.tf.example` uses string image references** (`image = "ubuntu-22.04-server-cloudimg-amd64"`) instead of a Terraform resource/data source ID. The Harvester provider `disk` block's `image` attribute expects a resource ID (e.g., `harvester_image.ubuntu.id`), not a display name string. | High | `team-template/rke2_cluster.tf.example:80,115` |
| T5 | **`postgresql_ha.tf.example` and `kv_store.tf.example` have the same string image reference issue** as T4. | High | `team-template/postgresql_ha.tf.example:161,203`, `team-template/kv_store.tf.example:95` |
| T6 | **Redis `requirepass ""` is set to empty string** — Redis will accept unauthenticated connections from any allowed network. | Medium | `team-template/kv_store.tf.example:72` |
| T7 | **Consul Option B has wrong hostname** — cloud-init sets `hostname: redis` and `fqdn: redis.${var.dns_domain}` instead of `hostname: consul`. This would cause DNS confusion if a team deploys Consul. | Medium | `team-template/kv_store.tf.example:148-149` |
| T8 | **Duplicate provider definitions when combining example files.** Both `coredns_stub_zone.tf.example` and `service_dns.tf.example` define `provider "kubernetes" { alias = "rke2" }`. If both are renamed to `.tf` and applied in the same workspace, Terraform will error on duplicate provider blocks. | Medium | `team-template/coredns_stub_zone.tf.example:50-53`, `team-template/service_dns.tf.example:43-46` |
| T9 | **Duplicate variable definition risk.** `coredns_stub_zone.tf.example` defines `variable "rke2_kubeconfig_path"`, but `service_dns.tf.example` uses the same variable without defining it. If only `service_dns.tf` is applied without `coredns_stub_zone.tf`, the variable will be undefined. | Medium | `team-template/service_dns.tf.example:45`, `team-template/coredns_stub_zone.tf.example:44` |
| T10 | **`rke2_cluster.tf.example` cloud-init uses `rke2-server` for all nodes** including workers. Workers should use `rke2-agent` service. Using `rke2-server` for workers would create an unintended multi-server etcd cluster. | High | `team-template/rke2_cluster.tf.example:57-59` |
| T11 | **`rke2_cluster.tf.example` cloud-init config** writes `server:` pointing to `manifest_url`, which is not correct for RKE2's `config.yaml`. The `server:` field should point to the first control plane node's IP/hostname with port 9345, not the registration manifest URL. | High | `team-template/rke2_cluster.tf.example:55` |
| T12 | **VyOS cloud-init `network_data` uses `gateway4`** which is deprecated in Netplan v2. Should use `routes` with `to: default, via: x.x.x.x`. This also affects `postgresql_ha.tf.example`, `kv_store.tf.example`, and `nginx_lb.tf`. | Low | All cloud-init `network_data` blocks |
| T13 | **No Terraform state backend configured** — all workspaces use local state by default. For a multi-team platform where multiple operators may run Terraform, remote state (S3, Consul, or Terraform Cloud) is essential to prevent state conflicts. | Medium | All `provider.tf` files |
| T14 | **`PRIV-TO-DATA` firewall rule 30 opens Redis port 6379 to the DATA VLAN**, but Redis is deployed in the SYSTEM VLAN (not DATA). This rule is architecturally incorrect — it allows traffic to port 6379 on the DATA VLAN where no Redis exists. It also contradicts the traffic matrix in AGENT.md which shows only PostgreSQL and Kafka in the DATA VLAN. | Medium | `cloudinit.tf:193-195`, `team-template/cloudinit.tf:193-195` |

### Recommendations

1. **T1:** Fix root-level `variables.tf` defaults to use valid subnets (`10.1.x.0/24`), or better yet, remove/deprecate root-level `.tf` files since `team-template/` is the canonical version.
2. **T4/T5:** Add an Ubuntu image data source or resource to the team-template (e.g., `data "harvester_image" "ubuntu" { display_name = "..." }`) and reference it from the example files as `data.harvester_image.ubuntu.id`.
3. **T7:** Change Consul Option B hostname from `redis` to `consul` and FQDN from `redis.${var.dns_domain}` to `consul.${var.dns_domain}`.
4. **T8/T9:** Consolidate the `kubernetes` provider definition and `rke2_kubeconfig_path` variable into a shared file (e.g., `rke2_provider.tf.example`) that teams copy once. Then `coredns_stub_zone.tf.example` and `service_dns.tf.example` can use `configuration_aliases` without re-declaring.
5. **T10/T11:** Split the RKE2 cloud-init into separate configs for control plane (uses `rke2-server` with `server: https://<rancher-url>`) and workers (uses `rke2-agent` with `server: https://<cp-ip>:9345`).
6. **T14:** Remove `PRIV-TO-DATA` rule 30 (Redis 6379) from both `cloudinit.tf` files. Redis traffic is already handled by `PRIV-TO-SYS` rule 40 which targets the correct SYSTEM VLAN.

---

## 3. Security Review

### Strengths

- **Three-layer VLAN conflict defence** (Terraform validation → Kyverno admission → audit script) is a robust, defence-in-depth approach.
- **Kyverno policy** is well-crafted with clear error messages, proper preconditions, and two complementary rules (allowlist check + annotation existence check).
- **Namespace-scoped RBAC** with dedicated ServiceAccounts and the `edit` ClusterRole is appropriate. Teams cannot access cluster-scoped resources.
- **Custom ClusterRole `harvester-namespace-user`** properly scopes Harvester CRD access (VMs, images, networks) without granting cluster-admin.
- **Rancher API keys** are marked as `sensitive` in variables.
- **`.gitignore` covers `terraform.tfvars`** and kubeconfig files — prevents accidental credential commits.
- **Namespace annotations** for VLAN allowlists are set by platform team and SRE teams cannot modify them (no PATCH permission on Namespace objects).

### Issues Found

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| S1 | **PostgreSQL passwords are passed in clear text via cloud-init** user_data, which is stored as a Kubernetes Secret. The Secret is base64-encoded (not encrypted) and visible in the Harvester UI, via `kubectl get secret -o yaml`, and in the VyOS cloud-init logs. | High | `team-template/postgresql_ha.tf.example:99-100` |
| S2 | **VyOS SSH listens only on mgmt IP** (good), but **password authentication is not explicitly disabled** in cloud-init. Default VyOS config allows password auth with default password `vyos`. | Medium | `cloudinit.tf:235-236` |
| S3 | **Redis has no password** (empty `requirepass`). Any VM or pod that can reach port 6379 on the SYSTEM VLAN can read/write all Redis data without authentication. | Medium | `team-template/kv_store.tf.example:72` |
| S4 | **PostgreSQL replication password** is embedded in cloud-init plaintext and visible to anyone who can read the cloud-init Secret. | Medium | `team-template/postgresql_ha.tf.example:100` |
| S5 | **`ALLOW-INTERNET` rule 20 is overly permissive** — it accepts ALL outbound traffic from all VLANs with no protocol/port/destination restrictions. A compromised VM could exfiltrate data to any destination or connect to C2 servers. | Medium | `cloudinit.tf:133`, `team-template/cloudinit.tf:133` |
| S6 | **Nginx proxy VM has `proxy_ssl_verify off`** — does not verify the kgateway TLS certificate. Acceptable in a lab but should be properly configured with the internal CA certificate in production to prevent MITM attacks. | Low | `deployments/openchoreo/nginx_lb.tf:76` |
| S7 | **`null_resource.copy_nginx_tls`** hardcodes `~/.ssh/id_ed25519` for the SSH private key path. This is not portable and leaks assumptions about the operator's key location. | Low | `deployments/openchoreo/nginx_lb.tf:189,200,211,228` |
| S8 | **No Kubernetes NetworkPolicy** within the RKE2 cluster. Once pods are on the PRIVATE VLAN, any pod can communicate with any other pod on any port. This is standard K8s behaviour but should be considered for production hardening. | Low | Gap |
| S9 | **PostgreSQL `pg_hba.conf` uses `md5` authentication** which is vulnerable to replay attacks. PostgreSQL 16 supports `scram-sha-256` which is more secure. | Low | `team-template/postgresql_ha.tf.example:86-88` |

### Recommendations

1. **S1/S4:** Use HashiCorp Vault or Kubernetes ExternalSecrets to inject database passwords rather than embedding them in cloud-init. Document this as a production hardening step.
2. **S2:** Add `set service ssh disable-password-authentication` to VyOS cloud-init in both `cloudinit.tf` files.
3. **S3:** Either set a real Redis password (`requirepass "your-strong-password"`) or document prominently that `requirepass` must be set before production use.
4. **S5:** Consider adding egress filtering — at minimum, restrict outbound to ports 80, 443, 53 (DNS), and NTP.
5. **S7:** Make the SSH private key path a variable with a sensible default.
6. **S9:** Change `md5` to `scram-sha-256` in `pg_hba.conf` and set `password_encryption = scram-sha-256` in `postgresql.conf`.

---

## 4. Documentation Review

### Strengths

- **AGENT.md is exceptional** — 815 lines covering architecture, VLAN allocation, traffic matrix, RBAC, DNS, troubleshooting, and capacity planning. It serves as both a reference and an onboarding guide.
- **WORKFLOW.md is comprehensive** — phased deployment approach (0→5) with checklists at each phase. Excellent for operational runbooks.
- **Deployment guides** (`deployments/openchoreo.md`, `openchoreo-integrations.md`) are thorough with architecture diagrams, step-by-step instructions, and troubleshooting sections.
- **The OpenChoreo integrations doc** explains every service-to-service connection flow packet-by-packet — rare to see this level of detail in infrastructure repos.
- **Code comments** are extensive and helpful, especially in cloud-init templates and firewall rules.
- **Example `terraform.tfvars` files** are well-annotated with formulas and references to the allocation table.

### Issues Found

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| D1 | **README.md is outdated** — still describes the single-team root-level workflow. Does not mention `infra/`, `team-template/`, the multi-team model, or Rancher integration. New users who start with README.md will follow a broken path. | High | `README.md` |
| D2 | **README traffic matrix is incorrect** — shows `PRIVATE→DATA: PG,Redis,Kafka` but Redis is in the SYSTEM VLAN. However, the VyOS firewall actually *does* have a `PRIV-TO-DATA` rule for Redis (port 6379), which is itself a bug (see T14). So the README matches the buggy firewall config rather than the intended architecture. | Medium | `README.md:23` |
| D3 | **AGENT.md traffic matrix is partially wrong** — shows `PRIVATE→DATA: PG(5432), Kafka(9092)` which is correct, but the actual firewall also opens Redis 6379 on DATA which contradicts AGENT.md (AGENT.md is architecturally correct; the code is wrong). | Medium | `AGENT.md:82` vs `cloudinit.tf:193-195` |
| D4 | **AGENT.md Section 4 directory listing is slightly incomplete** — does not mention the `deployments/openchoreo/` Terraform workspace directory or `deployments/openchoreo-integrations.md`. | Low | `AGENT.md:96-126` |
| D5 | **No CHANGELOG or version history.** Difficult to understand what changed between iterations or when features were added. | Low | Gap |
| D6 | **`gen-kubeconfig.sh` script is only documented inline** in WORKFLOW.md — not present as an actual file in the `scripts/` directory. | Low | `WORKFLOW.md:372-421` |
| D7 | **README mentions "Terraform >= 1.0"** as a prerequisite, but `provider.tf` requires `>= 1.5.0`. These are inconsistent. | Low | `README.md:33` vs `provider.tf:2` |

### Recommendations

1. **D1:** Rewrite `README.md` to redirect users to `AGENT.md` and `WORKFLOW.md`, remove the single-team Quick Start, and clearly explain the multi-team architecture with links to the appropriate docs.
2. **D2/D3:** Remove the spurious Redis rule from `PRIV-TO-DATA` (see T14), then update README.md's traffic matrix to match AGENT.md (which is correct).
3. **D6:** Create `scripts/gen-kubeconfig.sh` as a standalone script rather than embedding it in WORKFLOW.md documentation.
4. **D7:** Update README.md to specify `Terraform >= 1.5.0`.

---

## 5. Operational Readiness

### What Works Well

- **Audit script** (`scripts/audit-vlans.sh`) is well-written with colour-coded output, three distinct checks (out-of-allowlist, duplicates, unannotated namespaces), argument parsing, dependency checking, and a non-zero exit code for CI integration.
- **Phase-based workflow** in WORKFLOW.md provides clear ordering guarantees and checklists at each phase.
- **Team offboarding process** is documented with the critical note to never reuse VLAN offsets.
- **Troubleshooting guides** cover the most common failure modes with step-by-step diagnosis (VyOS unreachable, DHCP issues, VLAN traffic not passing, namespace not found, VLAN conflicts).
- **Deployment ordering** is clearly documented: infra → team VPC → RKE2 → PostgreSQL → KV Store.

### Gaps

| # | Gap | Severity |
|---|-----|----------|
| O1 | **No monitoring/alerting** for VyOS router health, DHCP pool exhaustion, firewall rule hit counts, or VM resource utilisation. | Medium |
| O2 | **No automated testing** — no CI pipeline, no `terraform fmt -check`, no `terraform validate` in CI, no integration tests. | Medium |
| O3 | **No disaster recovery procedure** for restoring a team VPC after a VyOS VM failure (e.g., corrupted disk, accidental deletion). | Medium |
| O4 | **`files-5.zip`** is tracked by git — appears to be an archive that should not be in version control. `.gitignore` has `*.zip` but this file was committed before the ignore rule was added. | Low |
| O5 | **VyOS image URL points to a nightly rolling build** (`1.5-rolling-202402120023` from Feb 2024). This is not a stable release, could disappear from GitHub, and is over 2 years old. | Medium |
| O6 | **No `terraform fmt` enforcement.** Some files have inconsistent indentation (tabs vs spaces in embedded YAML/HCL within heredocs). | Low |

### Recommendations

1. **O1:** Add a simple health check script or CronJob that pings VyOS management IPs, checks DHCP pool utilisation (`show dhcp server statistics`), and alerts on low pool availability.
2. **O2:** Add a CI pipeline (GitHub Actions) that runs `terraform fmt -check`, `terraform validate`, and `terraform plan` (with a mock backend) on PRs for each workspace (`infra/`, `team-template/`, `deployments/openchoreo/`).
3. **O3:** Document a VyOS recovery procedure: (1) `terraform apply` recreates the VM with the same config, (2) VMs with DHCP will re-register, (3) static IPs are unaffected.
4. **O4:** Remove `files-5.zip` from the repo with `git rm files-5.zip`.
5. **O5:** Pin the VyOS image to a stable LTS release or mirror it to an internal artifact registry.

---

## 6. OpenChoreo Deployment Workspace Review

### Strengths

- **Fully automated via Terraform** — the `deployments/openchoreo/` workspace automates everything from Nginx proxy VM creation to Helm chart installation, including Gateway API CRDs, cert-manager, and the internal CA chain.
- **Two-stage apply pattern** is well-documented and correctly handles the Thunder→OIDC→Control Plane chicken-and-egg dependency.
- **All secrets are managed via `kubernetes_secret_v1`** resources — not hardcoded in Helm values. Thunder DB credentials, Backstage DB credentials, and OIDC client credentials are all separate Secrets.
- **Proper dependency chains** (`depends_on`) ensure resources are created in the correct order, including a `null_resource.wait_for_thunder` that polls OIDC discovery before proceeding.
- **Outputs include a post-deployment checklist** with copy-pastable commands for operator convenience.
- **Internal CA chain** is properly set up: self-signed root → CA Certificate → CA ClusterIssuer for inter-service TLS.
- **The `choreo_k8s_services.tf` file includes a clear note** about potential conflict with `service_dns.tf` in the team workspace.

### Issues Found

| # | Issue | Severity | Location |
|---|-------|----------|----------|
| C1 | **cert-manager registry mismatch between Terraform and docs.** `choreo_prereqs.tf` uses `oci://quay.io/jetstack` while `openchoreo.md` references `oci://ghcr.io/cert-manager/charts/cert-manager`. Both are valid registries for cert-manager but should be consistent. | Medium | `deployments/openchoreo/choreo_prereqs.tf:43-44` vs `deployments/openchoreo.md:388-389` |
| C2 | **OpenChoreo version is a single variable for all charts** (`openchoreo_version`). Thunder, OpenChoreo control plane, and data plane may release on different cadences, and a single version variable would prevent upgrading them independently. | Low | `deployments/openchoreo/variables.tf:160-163` |
| C3 | **`null_resource.copy_nginx_tls` uses SSH `remote-exec`** which requires the Nginx VM to be directly reachable from the machine running Terraform. In some network topologies (e.g., Terraform running outside the management network), this will fail. | Low | `deployments/openchoreo/nginx_lb.tf:168-234` |
| C4 | **Potential conflict with team-workspace `service_dns.tf`.** If both `choreo_k8s_services.tf` (in the OpenChoreo workspace) and `service_dns.tf` (in the team workspace) are applied, the `postgres` and `postgres-ro` K8s Services will conflict. The file header documents this, but there is no programmatic guard. | Medium | `deployments/openchoreo/choreo_k8s_services.tf:18-19` |

### Recommendations

1. **C1:** Align the cert-manager registry — use the same OCI URL in both Terraform code and documentation.
2. **C4:** Add a variable like `create_postgres_service = true` (default `true`) to `choreo_k8s_services.tf` that allows operators to skip Service creation if `service_dns.tf` is already applied in the team workspace.

---

## 7. Code Duplication Analysis

The root-level `.tf` files and `team-template/` files are largely identical, with the team-template being the improved version. This duplication creates a maintenance burden and confusion risk.

| Root file | Team-template equivalent | Key differences |
|-----------|--------------------------|-----------------|
| `variables.tf` | `team-template/variables.tf` | Root has **invalid subnet defaults** (10.300.x, 10.400.x), missing validation blocks, `dns_domain` has a default (team-template has no default — forces explicit setting) |
| `cloudinit.tf` | `team-template/cloudinit.tf` | Identical content |
| `networks.tf` | `team-template/networks.tf` | Root references `harvester_clusternetwork.vpc_trunk.name` (resource); team-template correctly uses `var.cluster_network_name` (variable) |
| `vyos_router.tf` | `team-template/vyos_router.tf` | Identical content |
| `images.tf` | `team-template/images.tf` | Identical content |
| `outputs.tf` | `team-template/outputs.tf` | Root references `harvester_clusternetwork.vpc_trunk` (resource in scope); team-template correctly uses `var.cluster_network_name` |
| `provider.tf` | `team-template/provider.tf` | Root has only `harvester`; team-template adds `rancher2` provider |
| `cluster_network.tf` | (managed by `infra/main.tf`) | Root creates cluster-scoped ClusterNetwork and VLANConfig resources that only platform admins should manage |
| `workload_vms.tf.example` | `team-template/workload_vms.tf.example` | Both exist; team-template version correctly uses `vpc_vlans` resource name |

**Recommendation:** Remove or clearly mark the root-level `.tf` files as deprecated/legacy. The canonical template is `team-template/`, and the shared infrastructure is in `infra/`. The root files serve no purpose in the current multi-team architecture, contain known bugs (invalid subnets, cluster-scoped resource creation), and risk confusing new users.

---

## 8. Summary of Findings by Severity

### Critical (must fix before production use)

| # | Finding |
|---|---------|
| T1 | Invalid default subnet values in root `variables.tf` and `terraform.tfvars.example` (10.300.x, 10.400.x — octets > 255) |

### High (should fix soon)

| # | Finding |
|---|---------|
| T2 | Root-level `cluster_network.tf` creates cluster-scoped resources (conflicts with `infra/`) |
| T4 | `.tf.example` files use string image references instead of Terraform resource/data source IDs |
| T5 | Same string image reference issue in `postgresql_ha.tf.example` and `kv_store.tf.example` |
| T10 | RKE2 worker nodes use `rke2-server` instead of `rke2-agent` in shared cloud-init |
| T11 | RKE2 `config.yaml` uses `manifest_url` for `server:` field instead of control plane IP:9345 |
| S1 | PostgreSQL passwords visible in cloud-init Secrets (base64, not encrypted) |
| D1 | README.md is outdated — doesn't describe the multi-team architecture |

### Medium (should fix before production)

| # | Finding |
|---|---------|
| A1 | VyOS router is a single point of failure per team |
| A2 | No backup/restore strategy documented |
| T3 | Root-level files coexist with team-template causing confusion |
| T6 | Redis has no authentication configured (empty `requirepass`) |
| T7 | Consul Option B cloud-init has wrong hostname (`redis` instead of `consul`) |
| T8 | Duplicate `provider "kubernetes"` blocks if both `coredns_stub_zone.tf` and `service_dns.tf` are used |
| T9 | `rke2_kubeconfig_path` variable defined in one example but used in another |
| T13 | No remote state backend configured for any workspace |
| T14 | Spurious `PRIV-TO-DATA` rule 30 opens Redis port 6379 on DATA VLAN (Redis is in SYSTEM) |
| S2 | VyOS SSH password auth not explicitly disabled (default VyOS password `vyos` works) |
| S3 | Redis `requirepass` is empty — unauthenticated access |
| S4 | PostgreSQL replication password in plaintext cloud-init |
| S5 | Overly permissive outbound firewall rules (all traffic allowed to internet) |
| O1 | No monitoring/alerting for VyOS or infrastructure health |
| O2 | No CI pipeline for Terraform validation |
| O3 | No disaster recovery procedure documented |
| O5 | VyOS image is a 2-year-old nightly rolling build |
| C1 | cert-manager registry mismatch between Terraform code and docs |
| C4 | Potential K8s Service conflict between OpenChoreo workspace and team workspace |
| D2 | README traffic matrix matches buggy firewall (Redis in DATA) rather than intended architecture |
| D3 | AGENT.md traffic matrix is correct but conflicts with actual firewall rules |

### Low (nice to have)

| # | Finding |
|---|---------|
| A3 | 10-team scalability ceiling with current VLAN offset scheme |
| T12 | Deprecated `gateway4` in Netplan network_data (use `routes` instead) |
| S6 | Nginx `proxy_ssl_verify off` — acceptable in lab, not in production |
| S7 | Hardcoded SSH key path in Nginx TLS copy provisioner |
| S8 | No Kubernetes NetworkPolicy within the RKE2 cluster |
| S9 | PostgreSQL uses `md5` auth instead of `scram-sha-256` |
| D4-D7 | Minor documentation gaps and inconsistencies |
| O4 | `files-5.zip` committed to repo |
| O6 | No `terraform fmt` enforcement |
| C2 | Single version variable for all OpenChoreo charts |
| C3 | SSH remote-exec provisioner requires direct network access to Nginx VM |

---

## 9. Positive Highlights

These aspects are particularly well done and worth preserving:

1. **The three-layer VLAN conflict defence** (Terraform validation → Kyverno admission webhook → audit script) is a textbook defence-in-depth implementation. Each layer catches different failure modes with clear remediation instructions.
2. **The `extra_service_dns` variable design** is elegant — it allows arbitrary application DNS entries via a simple `map(string)` without modifying the core cloud-init template. New deployments just add entries.
3. **The OpenChoreo deployment workspace** demonstrates how to extend the platform for real applications — a complete, production-grade reference architecture with proper secret management and dependency ordering.
4. **The `openchoreo-integrations.md` document** is exceptional — packet-level request flow documentation from browser to pod, through every VyOS ruleset, with numbered steps. This is rare and invaluable for troubleshooting.
5. **The phased WORKFLOW.md** with checklists at each phase (0→5) is a model for operational runbooks. The two-role distinction (`[PLATFORM]` vs `[SRE]`) makes responsibilities crystal clear.
6. **The VLAN calculator** in AGENT.md makes it trivial for anyone to compute a new team's allocation with simple arithmetic.
7. **IP reservation design** (`.10-.99` for static services, `.100-.200` for DHCP) is simple, collision-free, and creates DNS records before VMs exist.
8. **The audit script** (`scripts/audit-vlans.sh`) is production-quality: proper bash (`set -euo pipefail`), argument parsing, dependency checks, colour-coded output, and CI-friendly exit codes.
9. **Namespace annotation design** — using `platform/allowed-vlans` as the single source of truth consumed by both Kyverno and the audit script, with platform-only write access, is a clean authorization model.

---

## 10. Revision Notes

### Corrections from initial report

The initial version of this report (2026-03-01) contained the following errors, now corrected:

| Original # | Original claim | Correction |
|------------|---------------|------------|
| T4 (old) | `rke2_cluster.tf.example` uses `harvester_network.vlans` (wrong name) | **False positive.** The file correctly uses `harvester_network.vpc_vlans` matching `networks.tf`. Verified via grep. |
| T5 (old) | `postgresql_ha.tf.example` and `kv_store.tf.example` use wrong resource name | **False positive.** Both files correctly use `harvester_network.vpc_vlans`. Verified via grep. |
| T11 (old) | `team-template/outputs.tf` references `harvester_clusternetwork.vpc_trunk` (not in scope) | **False positive.** The output correctly uses `var.cluster_network_name` (a variable), not a resource reference. |
| C2 (old) | `openchoreo_cp.tf` has duplicate YAML keys (`backstage`, `kgateway`) | **False positive.** Re-reading the YAML, `backstage:` appears once (with `database:`, `config:`, `resources:` sub-keys) and `kgateway:` appears once (with `service:`, `resources:` sub-keys). No duplication. |

### New findings added in this revision

| # | New finding |
|---|------------|
| T7 | Consul Option B cloud-init has wrong hostname (`redis` instead of `consul`) |
| T8 | Duplicate `provider "kubernetes"` blocks when combining example files |
| T9 | Variable definition mismatch between example files |
| T11 (new) | RKE2 config.yaml `server:` uses manifest_url instead of CP IP:9345 |
| T14 | Spurious `PRIV-TO-DATA` rule 30 opens Redis port on wrong VLAN |
| S9 | PostgreSQL uses weak `md5` auth instead of `scram-sha-256` |
| D3 | AGENT.md traffic matrix conflicts with actual firewall rules |
| D7 | README Terraform version inconsistency |
| C4 | K8s Service conflict risk between workspaces |
| O6 | No `terraform fmt` enforcement |

---

## 11. Conclusion

This repository represents a solid, well-thought-out infrastructure platform. The architecture is sound, the documentation is among the best I've seen for infrastructure repos, and the operational tooling (audit script, phased workflows, checklists) shows maturity.

The only critical issue is the invalid subnet defaults in the root-level `variables.tf` (T1), which is a legacy artifact that doesn't affect the canonical `team-template/` code. The high-severity issues are concentrated in two areas: (1) the RKE2 cluster example file needs rework for proper server/agent role separation and image references, and (2) the root-level legacy files should be deprecated.

The biggest strategic recommendations:

1. **Deprecate or remove the root-level `.tf` files** in favour of the `team-template/` and `infra/` structure. This eliminates T1, T2, T3, and an entire class of confusion.
2. **Rework `rke2_cluster.tf.example`** with separate control-plane and worker cloud-init configs, proper RKE2 join configuration, and image data source references.
3. **Remove the spurious Redis rule from `PRIV-TO-DATA`** (T14) to align the firewall with the documented architecture.
4. **Add a CI pipeline** that validates Terraform across all three workspaces.

With these changes, the platform would be production-ready with high confidence.
