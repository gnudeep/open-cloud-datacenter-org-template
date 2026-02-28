#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# audit-vlans.sh — Detect L2 VLAN conflicts across SRE namespaces
#
# Usage:
#   ./scripts/audit-vlans.sh
#   ./scripts/audit-vlans.sh --kubeconfig /path/to/kubeconfig
#   ./scripts/audit-vlans.sh --namespace-prefix sre-
#
# What it checks:
#   1. OUT-OF-ALLOWLIST — VLANs in use that don't match the namespace annotation
#   2. DUPLICATES       — same VLAN ID used in more than one namespace
#   3. UNANNOTATED      — sre-* namespaces missing the platform/allowed-vlans annotation
#
# Exit codes:
#   0  — clean, no conflicts found
#   1  — one or more conflicts found (suitable for CI/alerting)
#
# Run as a CronJob or in CI to catch any drift from the intended state.
# ══════════════════════════════════════════════════════════════
set -euo pipefail

# ── Defaults ──
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/harvester.yaml}"
NS_PREFIX="sre-"
ERRORS=0

# ── Argument parsing ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --namespace-prefix) NS_PREFIX="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

KC="kubectl --kubeconfig ${KUBECONFIG_PATH}"

# ── Check dependencies ──
for cmd in kubectl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required tool not found: ${cmd}" >&2
    exit 1
  fi
done

# ── Color codes ──
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  VLAN Conflict Audit — $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

# ══════════════════════════════════════════════════════════════
# Collect all NetworkAttachmentDefinitions in sre-* namespaces
# ══════════════════════════════════════════════════════════════
echo "Collecting NetworkAttachmentDefinitions from all ${NS_PREFIX}* namespaces..."

NAD_JSON=$($KC get networkattachmentdefinition \
  --all-namespaces \
  -o json 2>/dev/null) || {
  echo -e "${RED}ERROR: Could not list NetworkAttachmentDefinitions. Check kubeconfig and permissions.${NC}"
  exit 1
}

# Filter to sre-* namespaces only and extract VLAN details
NADS=$(echo "$NAD_JSON" | jq -r --arg prefix "$NS_PREFIX" '
  .items[]
  | select(.metadata.namespace | startswith($prefix))
  | {
      namespace: .metadata.namespace,
      name:      .metadata.name,
      vlan:      ((.spec.config // "{}") | fromjson | .vlan // 0)
    }
  | select(.vlan != 0)
  | "\(.namespace)\t\(.name)\t\(.vlan)"
')

if [[ -z "$NADS" ]]; then
  echo "  No VLAN-backed networks found in ${NS_PREFIX}* namespaces."
  echo ""
fi

# ══════════════════════════════════════════════════════════════
# Collect namespace annotations (allowed-vlans per namespace)
# ══════════════════════════════════════════════════════════════
NS_JSON=$($KC get namespace -o json 2>/dev/null) || {
  echo -e "${RED}ERROR: Could not list namespaces.${NC}"
  exit 1
}

get_allowed_vlans() {
  local ns="$1"
  echo "$NS_JSON" | jq -r --arg ns "$ns" '
    .items[]
    | select(.metadata.name == $ns)
    | .metadata.annotations["platform/allowed-vlans"] // ""
  '
}

# ══════════════════════════════════════════════════════════════
# CHECK 1 — Out-of-allowlist VLANs
# ══════════════════════════════════════════════════════════════
echo -e "${BOLD}Check 1: VLAN IDs vs namespace allowlists${NC}"
echo "─────────────────────────────────────────"

ALLOWLIST_ISSUES=0

while IFS=$'\t' read -r ns name vlan; do
  [[ -z "$ns" ]] && continue
  allowed=$(get_allowed_vlans "$ns")

  if [[ -z "$allowed" ]]; then
    echo -e "  ${RED}[UNANNOTATED]${NC}  ${ns}/${name}  VLAN=${vlan}"
    echo "    → Namespace has no platform/allowed-vlans annotation."
    echo "      Run: cd infra/ && terraform apply"
    ALLOWLIST_ISSUES=$((ALLOWLIST_ISSUES + 1))
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Check if vlan is in the comma-separated allowed list
  if echo "$allowed" | tr ',' '\n' | grep -qx "$vlan"; then
    echo -e "  ${GREEN}[OK]${NC}            ${ns}/${name}  VLAN=${vlan}  (allowed: ${allowed})"
  else
    echo -e "  ${RED}[CONFLICT]${NC}     ${ns}/${name}  VLAN=${vlan}  (allowed: ${allowed})"
    echo "    → VLAN ${vlan} is NOT in the allowlist for ${ns}."
    echo "      This may cause L2 traffic to leak into the wrong VPC."
    echo "      Action: terraform destroy + fix terraform.tfvars + terraform apply"
    ALLOWLIST_ISSUES=$((ALLOWLIST_ISSUES + 1))
    ERRORS=$((ERRORS + 1))
  fi
done <<< "$NADS"

if [[ $ALLOWLIST_ISSUES -eq 0 ]]; then
  echo -e "  ${GREEN}All VLAN IDs match their namespace allowlists.${NC}"
fi
echo ""

# ══════════════════════════════════════════════════════════════
# CHECK 2 — Duplicate VLAN IDs across namespaces
# ══════════════════════════════════════════════════════════════
echo -e "${BOLD}Check 2: Duplicate VLAN IDs across namespaces${NC}"
echo "─────────────────────────────────────────────"

DUPLICATE_ISSUES=0

# Build a map: vlan_id → list of "namespace/name" using it
declare -A VLAN_USERS
while IFS=$'\t' read -r ns name vlan; do
  [[ -z "$ns" ]] && continue
  key="$vlan"
  if [[ -v VLAN_USERS[$key] ]]; then
    VLAN_USERS[$key]="${VLAN_USERS[$key]} ${ns}/${name}"
  else
    VLAN_USERS[$key]="${ns}/${name}"
  fi
done <<< "$NADS"

for vlan in "${!VLAN_USERS[@]}"; do
  users="${VLAN_USERS[$vlan]}"
  count=$(echo "$users" | wc -w)
  if [[ "$count" -gt 1 ]]; then
    echo -e "  ${RED}[DUPLICATE]${NC}  VLAN ${vlan} is used by ${count} networks:"
    for user in $users; do
      echo "               • $user"
    done
    echo "    → TWO TEAMS ARE ON THE SAME L2 SEGMENT. Fix immediately."
    DUPLICATE_ISSUES=$((DUPLICATE_ISSUES + 1))
    ERRORS=$((ERRORS + 1))
  fi
done

if [[ $DUPLICATE_ISSUES -eq 0 ]]; then
  echo -e "  ${GREEN}No duplicate VLAN IDs found across namespaces.${NC}"
fi
echo ""

# ══════════════════════════════════════════════════════════════
# CHECK 3 — Unannotated sre-* namespaces (no allowlist set)
# ══════════════════════════════════════════════════════════════
echo -e "${BOLD}Check 3: Unannotated SRE namespaces${NC}"
echo "────────────────────────────────────"

UNANNOTATED_ISSUES=0

SRE_NAMESPACES=$(echo "$NS_JSON" | jq -r --arg prefix "$NS_PREFIX" '
  .items[]
  | select(.metadata.name | startswith($prefix))
  | .metadata.name
')

while read -r ns; do
  [[ -z "$ns" ]] && continue
  allowed=$(get_allowed_vlans "$ns")
  if [[ -z "$allowed" ]]; then
    echo -e "  ${YELLOW}[MISSING]${NC}  ${ns} — no platform/allowed-vlans annotation"
    echo "    → Run: cd infra/ && terraform apply"
    UNANNOTATED_ISSUES=$((UNANNOTATED_ISSUES + 1))
    ERRORS=$((ERRORS + 1))
  else
    echo -e "  ${GREEN}[OK]${NC}       ${ns} — allowed VLANs: ${allowed}"
  fi
done <<< "$SRE_NAMESPACES"

if [[ $UNANNOTATED_ISSUES -eq 0 ]] && [[ -n "$SRE_NAMESPACES" ]]; then
  echo -e "  ${GREEN}All SRE namespaces have VLAN allowlists.${NC}"
fi
if [[ -z "$SRE_NAMESPACES" ]]; then
  echo "  No ${NS_PREFIX}* namespaces found."
fi
echo ""

# ══════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
if [[ $ERRORS -eq 0 ]]; then
  echo -e "${BOLD}${GREEN}  RESULT: CLEAN — No VLAN conflicts detected.${NC}"
else
  echo -e "${BOLD}${RED}  RESULT: ${ERRORS} ISSUE(S) FOUND — Immediate action required.${NC}"
  echo ""
  echo -e "  ${BOLD}Remediation steps:${NC}"
  echo "  1. For OUT-OF-ALLOWLIST: team must terraform destroy and re-apply with correct VLAN IDs"
  echo "  2. For DUPLICATES:       both teams must coordinate; one must change their allocation"
  echo "  3. For UNANNOTATED:      platform admin must run terraform apply in infra/"
  echo ""
  echo "  Reference: AGENT.md Section 2 (VLAN allocation table)"
  echo "             WORKFLOW.md Phase 5 (troubleshooting)"
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

exit $ERRORS
