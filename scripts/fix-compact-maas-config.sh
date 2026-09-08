#!/usr/bin/env bash
#
# Ensure Compact MaaS OAuth issuer, gateway URL, and enrollment defaults match the cluster.
# Re-applies Helm cluster sets via console deploy.sh (does not rebuild images).
#
# Usage:
#   ./scripts/fix-compact-maas-config.sh              # diagnose only
#   ./scripts/fix-compact-maas-config.sh --apply-fix  # helm-only reconfigure
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/compact-maas-cluster.sh
source "$SCRIPT_DIR/lib/compact-maas-cluster.sh"

COMPACT_MAAS_DIR="${COMPACT_MAAS_DIR:-${MAAS_CONSOLE_DIR:-}}"
if [[ -z "$COMPACT_MAAS_DIR" ]]; then
  if [[ -d "$GUIDE_DIR/../compact-maas" ]]; then
    COMPACT_MAAS_DIR="$(cd "$GUIDE_DIR/../compact-maas" && pwd)"
  elif [[ -d "$GUIDE_DIR/../rhoai-maas-console" ]]; then
    COMPACT_MAAS_DIR="$(cd "$GUIDE_DIR/../rhoai-maas-console" && pwd)"
  fi
fi

APPLY_FIX=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply-fix) APPLY_FIX=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! oc whoami &>/dev/null; then
  echo "ERROR: oc login required" >&2
  exit 1
fi

if [[ -z "$COMPACT_MAAS_DIR" || ! -f "$COMPACT_MAAS_DIR/scripts/deploy.sh" ]]; then
  echo "ERROR: Set COMPACT_MAAS_DIR to rhoai-maas-console checkout with scripts/deploy.sh" >&2
  exit 1
fi

domain="$(compact_maas_cluster_domain)"
echo "==> Cluster domain: ${domain:-unknown}"
echo "==> Expected OAuth issuer: $(compact_maas_oauth_issuer)"
echo "==> Expected gateway: $(compact_maas_gateway_url)"

if [[ "$APPLY_FIX" == true ]]; then
  echo "==> Re-applying Compact MaaS Helm cluster sets..."
  (
    cd "$COMPACT_MAAS_DIR"
    export CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$domain}"
    SKIP_BUILDS=1 ./scripts/deploy.sh --helm-only
  )
  sleep 2
  if compact_maas_verify_deployment_config compact-maas; then
    echo "[OK] OAuth / gateway / enrollment config matches cluster."
    exit 0
  fi
  echo "[FAIL] Config still mismatched after helm re-apply."
  compact_maas_verify_deployment_config compact-maas || true
  exit 1
fi

if compact_maas_verify_deployment_config compact-maas; then
  echo "[OK] OAuth / gateway / enrollment config matches cluster."
  exit 0
fi

echo "[FAIL] Compact MaaS deployment config mismatch:"
compact_maas_verify_deployment_config compact-maas 2>&1 || true
echo ""
echo "Re-run: ./scripts/fix-compact-maas-config.sh --apply-fix"
exit 1
