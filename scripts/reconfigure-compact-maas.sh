#!/usr/bin/env bash
# Re-apply Compact MaaS Helm values from the connected cluster (OAuth, gateway, enrollment).
# Thin wrapper — prefer ./scripts/fix-compact-maas-config.sh --apply-fix directly.
#
# Usage (from rhoai-maas-guide root):
#   ./scripts/reconfigure-compact-maas.sh
#   COMPACT_MAAS_DIR=/path/to/rhoai-maas-console ./scripts/reconfigure-compact-maas.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! oc whoami &>/dev/null; then
  echo "ERROR: oc login required" >&2
  exit 1
fi

export CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')}"
if [[ -z "$CLUSTER_DOMAIN" ]]; then
  echo "ERROR: cannot detect cluster domain" >&2
  exit 1
fi

echo "==> Reconfigure Compact MaaS for cluster domain: ${CLUSTER_DOMAIN}"
"$SCRIPT_DIR/fix-compact-maas-config.sh" --apply-fix
