#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# gen-kubeconfig.sh — Generate a namespace-scoped kubeconfig for an SRE team
#
# Usage:
#   ./scripts/gen-kubeconfig.sh <team-name> [--kubeconfig <path>] [--duration <duration>]
#
# Examples:
#   ./scripts/gen-kubeconfig.sh sre-alpha
#   ./scripts/gen-kubeconfig.sh sre-beta --kubeconfig ~/.kube/mycluster.yaml
#   ./scripts/gen-kubeconfig.sh sre-gamma --duration 4380h
#
# Output:
#   kubeconfig-<team-name>.yaml  (in the current directory)
#
# Prerequisites:
#   - kubectl in PATH, configured with admin access to the Harvester cluster
#   - The team's ServiceAccount must already exist (created by infra/ Terraform)
#   - Kubernetes >= 1.24 (uses 'kubectl create token' for short-lived tokens)
#
# Security:
#   - The kubeconfig is scoped to the team namespace only (via ServiceAccount RBAC)
#   - Token expires after --duration (default 8760h = 1 year); rotate as needed
#   - Deliver the kubeconfig to the team securely (not via git or chat)
# ══════════════════════════════════════════════════════════════

set -euo pipefail

# ── Defaults ──
TEAM_NAME=""
KUBECONFIG_ADMIN="${KUBECONFIG:-$HOME/.kube/harvester.yaml}"
TOKEN_DURATION="8760h"

# ── Parse arguments ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)
      KUBECONFIG_ADMIN="$2"
      shift 2
      ;;
    --duration)
      TOKEN_DURATION="$2"
      shift 2
      ;;
    -h|--help)
      head -20 "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      TEAM_NAME="$1"
      shift
      ;;
  esac
done

if [[ -z "$TEAM_NAME" ]]; then
  echo "Error: team name is required." >&2
  echo "Usage: $0 <team-name> [--kubeconfig <path>] [--duration <duration>]" >&2
  exit 1
fi

NAMESPACE="${TEAM_NAME}"
SA_NAME="${TEAM_NAME}-deployer"
OUT_FILE="kubeconfig-${TEAM_NAME}.yaml"

# ── Prerequisite checks ──
if ! command -v kubectl &>/dev/null; then
  echo "Error: kubectl is not in PATH." >&2
  exit 1
fi

if [[ ! -f "$KUBECONFIG_ADMIN" ]]; then
  echo "Error: admin kubeconfig not found at '${KUBECONFIG_ADMIN}'." >&2
  echo "Pass a different path with --kubeconfig." >&2
  exit 1
fi

# Verify the ServiceAccount exists before proceeding
if ! kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
    get serviceaccount "${SA_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo "Error: ServiceAccount '${SA_NAME}' not found in namespace '${NAMESPACE}'." >&2
  echo "Has the platform team run 'terraform apply' in infra/ for this team?" >&2
  exit 1
fi

echo "Generating kubeconfig for ${TEAM_NAME} (token expires in ${TOKEN_DURATION})..."

# ── Create a time-limited token ──
TOKEN=$(kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
  create token "${SA_NAME}" \
  --namespace "${NAMESPACE}" \
  --duration "${TOKEN_DURATION}")

# ── Pull cluster connection info from admin kubeconfig ──
CLUSTER_SERVER=$(kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
  config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
  config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# ── Write the scoped kubeconfig ──
cat > "${OUT_FILE}" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${CLUSTER_SERVER}
    certificate-authority-data: ${CA_DATA}
  name: harvester
contexts:
- context:
    cluster: harvester
    namespace: ${NAMESPACE}
    user: ${SA_NAME}
  name: ${TEAM_NAME}
current-context: ${TEAM_NAME}
users:
- name: ${SA_NAME}
  user:
    token: ${TOKEN}
EOF

chmod 600 "${OUT_FILE}"

echo ""
echo "Written: ${OUT_FILE}"
echo ""
echo "Verify access (should show resources in namespace '${NAMESPACE}' only):"
echo "  kubectl --kubeconfig ${OUT_FILE} get virtualmachines -n ${NAMESPACE}"
echo ""
echo "Deliver this file to the ${TEAM_NAME} team securely (not via git or public chat)."
echo "The token expires in ${TOKEN_DURATION} — regenerate before expiry."
