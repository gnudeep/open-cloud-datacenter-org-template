# Repository Review Report (Updated)

## Scope
Static review of Terraform stacks and supporting scripts/docs in the current repository state.

## Findings (ordered by severity)

### 1. High: Root `terraform.tfvars.example` contains invalid CIDRs for `system` and `data` VLANs
- Severity: High
- Files:
- `terraform.tfvars.example:41`
- `terraform.tfvars.example:46`
- Supporting reference:
- `variables.tf:53`
- Problem:
The example uses `10.300.0.0/24` and `10.400.0.0/24`, which are invalid IPv4 CIDRs.
- Impact:
Users copying this example will fail plan/apply or create inconsistent network assumptions versus the variable formula (`10.N.x.0/24`).
- Recommendation:
Update example values to valid per-team subnets (for example `10.1.2.0/24` and `10.1.3.0/24` for `N=1`).

### 2. High: Team examples reference a non-existent Terraform resource name
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
Examples reference `harvester_network.vlans[...]`, but the declared resource is `harvester_network.vpc_vlans`.
- Impact:
Copying examples into active `.tf` files causes immediate Terraform failures (`Reference to undeclared resource`).
- Recommendation:
Replace `harvester_network.vlans` with `harvester_network.vpc_vlans` in all affected example files.

### 3. High: `rke2_cluster.tf.example` bootstrapping logic is inconsistent for control-plane vs worker nodes
- Severity: High
- Files:
- `team-template/rke2_cluster.tf.example:55`
- `team-template/rke2_cluster.tf.example:57`
- `team-template/rke2_cluster.tf.example:58`
- `team-template/rke2_cluster.tf.example:59`
- Problem:
A single cloud-init template is reused for both control-plane and worker VMs, sets `server:` to `cluster_registration_token.manifest_url`, and starts `rke2-server` on all nodes.
- Impact:
Workers are not configured as agents, and `manifest_url` is not a stable substitute for the RKE2 server endpoint. This is likely to produce failed or incorrect cluster registration/bootstrapping.
- Recommendation:
Split cloud-init by role (`rke2-server` for control plane, `rke2-agent` for workers) and use Rancher-supported registration flow/endpoint semantics.

### 4. Medium: OpenChoreo Nginx TLS provisioning hardcodes a local SSH key path
- Severity: Medium
- File:
- `deployments/openchoreo/nginx_lb.tf:186`
- Problem:
`private_key = file("~/.ssh/id_ed25519")` assumes a specific key type/path and local filesystem layout.
- Impact:
`terraform apply` fails in environments using different key paths, key types, or SSH-agent-only workflows.
- Recommendation:
Parameterize SSH auth (key path variable or `agent = true`) and avoid hardcoded home-path assumptions.

### 5. Medium: Redis example ships with authentication effectively disabled
- Severity: Medium
- File:
- `team-template/kv_store.tf.example:71`
- Problem:
Redis config sets `requirepass ""`.
- Impact:
Any reachable workload can access/modify Redis data without authentication.
- Recommendation:
Require non-empty password by default, store it securely, and document rotation/secret-injection flow.

### 6. Medium: CoreDNS customization resource can overwrite shared `coredns-custom` ownership
- Severity: Medium
- Files:
- `deployments/openchoreo/choreo_k8s_services.tf:106`
- `team-template/coredns_stub_zone.tf.example:60`
- Problem:
Both stacks manage the same `kube-system/coredns-custom` ConfigMap directly.
- Impact:
Applying one stack can overwrite keys managed by another stack/tool, causing DNS regression and drift.
- Recommendation:
Use a single owner for `coredns-custom`, or merge existing keys explicitly (or move to a dedicated, centrally-managed DNS customization workflow).

### 7. Low: Gateway API CRDs are fetched at apply time without integrity pinning
- Severity: Low
- File:
- `deployments/openchoreo/choreo_prereqs.tf:31`
- Problem:
`kubectl apply -f https://...` pulls manifests live during apply based only on version tag.
- Impact:
Reduced reproducibility and weaker supply-chain guarantees.
- Recommendation:
Vendor/pin CRD manifests in-repo (or verify checksums/signatures) and apply from known content.

## Open Questions / Assumptions
- Assumed `team-template/*.example` files are intended to be copied and applied with minimal edits.
- Assumed `team-template/rke2_cluster.tf.example` is expected to produce a functional Rancher-managed RKE2 cluster as-is after standard variable filling.

## Residual Risks / Gaps
- This review is static analysis only; no live infrastructure apply was executed.
- No automated end-to-end validation exists across `infra` -> `team-template` -> `deployments/openchoreo` workflows.

## Suggested Next Actions
1. Fix blocking template correctness issues first (`terraform.tfvars.example` CIDRs, `harvester_network.vlans` references, RKE2 role bootstrap split).
2. Harden operational/security defaults (SSH auth parameterization, Redis auth defaults).
3. Define a single ownership model for `coredns-custom` and pin external CRD artifacts for deterministic applies.
