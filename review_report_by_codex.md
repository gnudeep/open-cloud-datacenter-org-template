# Repository Review Report

## Findings (ordered by severity)

### 1. Critical: OpenChoreo Helm values contain duplicate YAML keys that override required config
- Severity: Critical
- Files:
- `deployments/openchoreo/openchoreo_cp.tf:46`
- `deployments/openchoreo/openchoreo_cp.tf:98`
- `deployments/openchoreo/openchoreo_cp.tf:63`
- `deployments/openchoreo/openchoreo_cp.tf:107`
- Problem:
The inline YAML passed to `helm_release.openchoreo_cp` defines `backstage:` twice and `kgateway:` twice. In YAML, duplicate keys are not merged; later keys override earlier keys.
- Impact:
`backstage.database` configuration can be dropped, and `kgateway.service.type`/NodePort settings can be overwritten. This can break DB wiring and ingress behavior while appearing syntactically valid.
- Recommendation:
Merge each duplicated block into a single `backstage` and single `kgateway` mapping.

### 2. High: Multiple team-template examples reference a non-existent Terraform resource name
- Severity: High
- Files:
- `team-template/rke2_cluster.tf.example:86`
- `team-template/rke2_cluster.tf.example:121`
- `team-template/kv_store.tf.example:102`
- `team-template/postgresql_ha.tf.example:175`
- `team-template/postgresql_ha.tf.example:217`
- Supporting definition:
- `team-template/networks.tf:5`
- Problem:
Examples reference `harvester_network.vlans[...]`, but the actual resource is `harvester_network.vpc_vlans`.
- Impact:
Copying these examples into active `.tf` files causes immediate Terraform plan/apply failures (`Reference to undeclared resource`).
- Recommendation:
Replace `harvester_network.vlans` with `harvester_network.vpc_vlans` across all examples.

### 3. High: TLS copy provisioner hardcodes an SSH private key path and likely fails on many environments
- Severity: High
- File:
- `deployments/openchoreo/nginx_lb.tf:186`
- Problem:
`private_key = file("~/.ssh/id_ed25519")` is hardcoded. This assumes key location, key type, and home expansion behavior. Terraform `file()` does not reliably resolve shell-style `~` in all contexts.
- Impact:
Provisioning of TLS certs to Nginx can fail, leaving Nginx unusable (TLS files missing) after `apply`.
- Recommendation:
Introduce a variable for private key path and use an absolute path (or use `agent = true` SSH forwarding).

### 4. High: Redis example deploys with empty password (`requirepass ""`)
- Severity: High
- File:
- `team-template/kv_store.tf.example:71`
- Problem:
The provided default Redis config explicitly disables authentication.
- Impact:
Any workload on allowed paths can access and mutate Redis data without auth, enabling lateral abuse and data tampering.
- Recommendation:
Require authentication by default, source password from secret management, and document secure defaults.

### 5. Medium: Postgres secrets and passwords are injected into cloud-init/state in plaintext
- Severity: Medium
- Files:
- `team-template/postgresql_ha.tf.example:99`
- `team-template/postgresql_ha.tf.example:100`
- `deployments/openchoreo/choreo_k8s_setup.tf:65`
- `deployments/openchoreo/choreo_k8s_setup.tf:88`
- Problem:
Database credentials are passed through Terraform-managed strings and cloud-init content.
- Impact:
Sensitive values may be exposed in Terraform state, logs, and VM metadata paths unless state/backend protections are strict.
- Recommendation:
Use external secret stores (Vault, SOPS, or platform secret manager), and avoid embedding sensitive values in cloud-init where possible.

### 6. Medium: Code style consistency check fails across many Terraform files
- Severity: Medium
- Evidence:
- `terraform fmt -check -recursive` returned non-zero and listed multiple files (`cloudinit.tf`, `infra/namespaces_rbac.tf`, `deployments/openchoreo/*.tf`, etc.).
- Impact:
Higher review noise and avoidable diffs; harder to enforce stable IaC standards in CI.
- Recommendation:
Run `terraform fmt -recursive` and add a CI formatting gate.

### 7. Low: README prerequisites conflict with Terraform constraint
- Severity: Low
- Files:
- `README.md:32`
- `provider.tf:2`
- Problem:
README states `Terraform >= 1.0`, while code requires `>= 1.5.0`.
- Impact:
Users on 1.0-1.4 will fail after following docs.
- Recommendation:
Align README with actual requirement (`>= 1.5.0`).

## Open Questions / Assumptions
- Assumed `team-template/*.example` files are intended to be copied into production `.tf` files without additional manual refactoring.
- Assumed OpenChoreo chart values in `openchoreo_cp.tf` are meant to include both DB wiring and resource settings simultaneously (current duplicate keys prevent that reliably).

## Residual Risks and Testing Gaps
- No automated Terraform validation/lint pipeline is present in this repository snapshot.
- No integration test harness for critical deployment flows (`infra` -> `team-template` -> `deployments/openchoreo`).
- Network and policy behavior (Kyverno + VyOS firewall + CoreDNS stub zones) is documented but not regression-tested in CI.

## Suggested Next Actions
1. Fix the two blocking classes first: duplicate YAML keys in `openchoreo_cp.tf` and broken resource references in team examples.
2. Parameterize SSH private key handling for Nginx TLS copy and remove insecure defaults from Redis example.
3. Add CI checks: `terraform fmt -check -recursive`, `terraform validate` per workspace, and optionally `tflint`.
