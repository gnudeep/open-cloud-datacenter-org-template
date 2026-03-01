# Deployment Guides

This directory contains step-by-step deployment guides for specific application stacks on the
multi-team SRE VLAN platform. Each guide covers the full lifecycle: DNS setup, PostgreSQL provisioning,
Kubernetes prerequisites, application installation, and verification.

---

## Available Guides

| Guide | Stack | VLANs Used | Guide File |
|-------|-------|-----------|------------|
| [OpenChoreo](./openchoreo.md) | OpenChoreo v0.16+ API platform | PUBLIC (LB), PRIVATE (K8s), SYSTEM (KV optional), DATA (PG) | `openchoreo.md` |

---

## Common Prerequisites (all guides)

Before following any deployment guide, ensure the following are in place:

### 1. Platform layer (infra/) is applied

```bash
cd infra/
terraform apply   # run by platform team — creates namespaces, RBAC, VLAN annotations
```

### 2. Team VPC is running

```bash
cd my-team-vpc/
terraform apply   # creates VyOS router + 4 VLAN networks
```

Verify VyOS is healthy:

```bash
ssh vyos@192.168.1.<N*10>
show interfaces
show firewall zone-policy
show dhcp server statistics
```

### 3. RKE2 K8s cluster is registered with Rancher

Copy `rke2_cluster.tf.example` → `rke2_cluster.tf`, configure your Rancher credentials in
`terraform.tfvars`, and apply. The cluster must be in **Active** state in the Rancher UI before
proceeding with any application deployment.

### 4. PostgreSQL is running (if the guide requires it)

Copy `postgresql_ha.tf.example` → `postgresql_ha.tf` and apply. Confirm primary is listening:

```bash
ssh ubuntu@10.N.3.10
psql -U postgres -c "SELECT version();"
```

### 5. VyOS DNS is resolving service names

```bash
# From any VLAN VM or VyOS itself:
dig @10.N.1.1 postgres.sre-<team>.internal    # → 10.N.3.10
dig @10.N.1.1 redis.sre-<team>.internal       # → 10.N.2.10
```

---

## How Deployment Guides Are Structured

Each guide follows this pattern:

1. **Architecture diagram** — which component goes in which VLAN and why
2. **IP and DNS allocation** — which reserved IPs and service names to register
3. **Terraform changes** — `terraform.tfvars` additions (mainly `extra_service_dns`)
4. **Infrastructure VMs** — any LB proxy or sidecar VMs needed in PUBLIC VLAN
5. **Database setup** — SQL statements to create databases and users
6. **Kubernetes prerequisites** — CRDs, operators, cert-manager, etc.
7. **Application installation** — Helm releases with minimal values
8. **Verification** — expected output from health-check commands
9. **Troubleshooting** — common failure modes

---

## Adding a New Deployment Guide

When you add a guide for a new workload type:

1. Create `deployments/<workload-name>.md` following the pattern above.
2. Add a row to the table at the top of this README.
3. If the workload requires new VyOS firewall rules, document the change in the guide and note
   that the user needs to add them to their `cloudinit.tf`.
4. Update `AGENT.md` Section 4 (directory listing) to reference the new guide.

---

## Reserved IP Ranges (Quick Reference)

Each team's VPC reserves `.10-.99` in each zone for named service VMs.
The DHCP pool starts at `.100`.

| Zone    | Reserved Range | Purpose |
|---------|---------------|---------|
| PUBLIC  | 10.N.0.10-.99 | LB proxy VMs, Nginx, MetalLB pool |
| PRIVATE | 10.N.1.10-.99 | K8s control-plane VIPs |
| SYSTEM  | 10.N.2.10-.99 | Redis (.10), Vault (.11), Registry (.12), ... |
| DATA    | 10.N.3.10-.99 | PostgreSQL primary (.10), standby (.11), Kafka (.20+) |

Where `N` is your team offset (sre-alpha = 1, sre-beta = 2, ...).
