# Repository Review Report (Updated)

## Scope
Static code review of Terraform stacks, examples, and deployment helpers in the current repository snapshot.

## Findings (ordered by severity)

### 1. High: PostgreSQL example provisions a `pgdata` disk but never mounts/uses it
- Severity: High
- Files:
- `team-template/postgresql_ha.tf.example:166`
- `team-template/postgresql_ha.tf.example:209`
- `team-template/postgresql_ha.tf.example:136`
- Problem:
Both primary and standby VMs attach a 200Gi `pgdata` disk, but the cloud-init flow never formats/mounts that disk nor points PostgreSQL `data_directory` to it.
- Impact:
PostgreSQL continues using the root disk (`/var/lib/postgresql/...`), so the extra storage is effectively unused. This can cause premature root disk exhaustion and outage under write-heavy workloads.
- Recommendation:
Initialize and mount the data disk (e.g., `/var/lib/postgresql`) and set ownership/permissions before PostgreSQL starts.

### 2. Medium: “HA” PostgreSQL example does not implement automated failover
- Severity: Medium
- Files:
- `team-template/postgresql_ha.tf.example:2`
- `team-template/postgresql_ha.tf.example:14`
- `team-template/postgresql_ha.tf.example:15`
- Problem:
The file is labeled as HA and creates primary/standby, but it has no failover manager (Patroni/repmgr/Pacemaker), no promotion automation, and DNS remains statically pinned to fixed roles.
- Impact:
Primary failure requires manual intervention for promotion and endpoint switching; availability behavior does not match typical HA expectations.
- Recommendation:
Either rename/document this as manual failover replication, or add explicit failover orchestration and role-aware service routing.

### 3. Medium: Standby initialization is one-shot and fragile on first boot timing
- Severity: Medium
- Files:
- `team-template/postgresql_ha.tf.example:135`
- `team-template/postgresql_ha.tf.example:141`
- `team-template/postgresql_ha.tf.example:230`
- Problem:
Standby bootstrapping relies on a single `pg_basebackup` execution during cloud-init. VM dependency only enforces primary resource creation, not Postgres readiness/accepting replication connections.
- Impact:
If primary is not fully ready during standby first boot, replica initialization can fail and remain broken until manual repair.
- Recommendation:
Add readiness polling/retry logic for primary availability before `pg_basebackup`, and fail clearly with recoverable rerun steps.

### 4. Medium: Secrets are embedded into Terraform-managed values and cloud-init scripts
- Severity: Medium
- Files:
- `team-template/postgresql_ha.tf.example:100`
- `team-template/postgresql_ha.tf.example:101`
- `deployments/openchoreo/choreo_k8s_setup.tf:65`
- `deployments/openchoreo/choreo_k8s_setup.tf:88`
- Problem:
Database passwords are passed directly through Terraform resources/user-data.
- Impact:
Secrets can appear in Terraform state and operational logs unless backend/state handling is strictly secured.
- Recommendation:
Use external secret sources (Vault/SOPS/secret manager), minimize direct secret interpolation in cloud-init, and enforce encrypted remote state with limited access.

### 5. Low: Gateway API CRDs are applied directly from remote URLs at apply time
- Severity: Low
- File:
- `deployments/openchoreo/choreo_prereqs.tf:31`
- Problem:
`kubectl apply` fetches CRDs from GitHub release URLs during each install/upgrade path.
- Impact:
Less deterministic builds and weaker supply-chain integrity guarantees compared with vendored/pinned artifacts.
- Recommendation:
Vendor CRD manifests in-repo (or checksum-verify downloaded artifacts) and apply from known content.

## Open Questions / Assumptions
- Assumed `team-template/postgresql_ha.tf.example` is intended for production-like usage, not only lab demonstration.
- Assumed manual failover behavior is currently undesired for the documented “HA” posture.

## Residual Risks / Testing Gaps
- No automated integration validation covering full flow (`infra` -> `team-template` -> `deployments/openchoreo`).
- This review is static-only; no live `terraform apply` or runtime failover testing was executed.

## Suggested Next Actions
1. Fix storage correctness first: mount/use `pgdata` for primary and standby before service start.
2. Decide and document target availability model (manual failover vs automated failover) and align implementation.
3. Add readiness/retry guards for standby bootstrap and move sensitive credentials to external secret management.
