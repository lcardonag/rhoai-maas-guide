#!/usr/bin/env bash
#
# Ensure gateway POST /maas-api/v1/api-keys works after Compact MaaS deploy.
# Re-applies the console-owned BBR anchor with maas-api route bypass (does not delete it).
#
# Usage:
#   ./scripts/fix-compact-maas-native-maas.sh              # diagnose only
#   ./scripts/fix-compact-maas-native-maas.sh --apply-fix  # re-apply fixed anchor
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

FIX_SCRIPT=""
if [[ -n "$COMPACT_MAAS_DIR" && -x "$COMPACT_MAAS_DIR/scripts/fix-payload-processing-envoyfilter.sh" ]]; then
  FIX_SCRIPT="$COMPACT_MAAS_DIR/scripts/fix-payload-processing-envoyfilter.sh"
else
  echo "ERROR: Set COMPACT_MAAS_DIR to rhoai-maas-console with fix-payload-processing-envoyfilter.sh" >&2
  exit 1
fi

GW="$(compact_maas_gateway_url)"
echo "==> Native MaaS gateway: ${GW:-unknown}"
echo "==> maas-api namespace: $(compact_maas_maas_api_namespace)"

if [[ "$APPLY_FIX" == true ]]; then
  echo "==> Applying BBR anchor (with maas-api bypass)..."
  "$FIX_SCRIPT"
  sleep 3
  if compact_maas_verify_native_key_mint; then
    echo "[OK] Key mint works (POST /maas-api/v1/api-keys)."
    compact_maas_revoke_ephemeral_key
    exit 0
  fi
  echo "[FAIL] Key mint still failing (HTTP ${COMPACT_MAAS_LAST_KEY_HTTP_CODE:-?}) after anchor re-apply."
  exit 1
fi

if compact_maas_verify_native_key_mint; then
  echo "[OK] Gateway key mint succeeded (subscription: $(compact_maas_pick_test_subscription))"
  compact_maas_revoke_ephemeral_key
  if ! compact_maas_bbr_anchor_present; then
    echo "[WARN] compact-maas-bbr-anchor missing — ExternalModel chat may 401; run with --apply-fix"
  fi
  exit 0
fi

echo "[FAIL] Gateway key mint failed (HTTP ${COMPACT_MAAS_LAST_KEY_HTTP_CODE:-?})"
if [[ -n "${COMPACT_MAAS_LAST_KEY_BODY:-}" ]]; then
  echo "       Response: ${COMPACT_MAAS_LAST_KEY_BODY:0:200}"
fi

log_line="$(compact_maas_maas_api_missing_username_log)"
[[ -n "$log_line" ]] && echo "[HINT] maas-api log: ${log_line}"

if compact_maas_bbr_anchor_present; then
  echo "[HINT] Re-apply upgraded anchor: $FIX_SCRIPT"
else
  echo "[HINT] Apply anchor: $FIX_SCRIPT"
fi
echo ""
echo "Re-run: ./scripts/fix-compact-maas-native-maas.sh --apply-fix"
exit 1
