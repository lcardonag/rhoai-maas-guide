#!/usr/bin/env bash
#
# Soft verification for optional GUI phases (LiteMaaS and/or Compact MaaS).
# Does not fail the overall MaaS install hard — exits 0 with warnings, or 1 if
# a requested GUI is missing entirely.
#
# Usage:
#   ./scripts/verify-guis.sh                 # check whichever namespaces exist
#   ./scripts/verify-guis.sh --litemaas
#   ./scripts/verify-guis.sh --compact-maas
#   ./scripts/verify-guis.sh --litemaas --compact-maas
#
# When Compact MaaS is checked, gateway POST /maas-api/v1/api-keys is always
# verified (native MaaS must not be broken). Use --soft-native to warn only.
#
# Deprecated aliases: --maas-console (same as --compact-maas); --strict-native (no-op)
#
set -euo pipefail

CHECK_LITE=false
CHECK_COMPACT=false
STRICT_NATIVE=false
SOFT_NATIVE=false
if [[ $# -eq 0 ]]; then
  CHECK_LITE=true
  CHECK_COMPACT=true
  AUTO=true
else
  AUTO=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --litemaas) CHECK_LITE=true; shift ;;
      --compact-maas|--maas-console) CHECK_COMPACT=true; shift ;;
      --strict-native) shift ;;  # deprecated: strict is default for --compact-maas
      --soft-native) SOFT_NATIVE=true; shift ;;
      -h|--help)
        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
fi

# Compact MaaS is an optional layer on native MaaS — always regression-test key mint.
if [[ "$CHECK_COMPACT" == true && "$SOFT_NATIVE" != true ]]; then
  STRICT_NATIVE=true
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

FAILURES=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_litemaas() {
  local ns=litemaas
  if ! oc get ns "$ns" &>/dev/null; then
    if [ "$AUTO" = true ]; then
      warn "Namespace $ns not found (LiteMaaS not installed — skip)"
      return 0
    fi
    err "Namespace $ns missing (expected with --with-litemaas)"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  ok "Namespace $ns exists"

  local ready
  ready=$(oc -n "$ns" get deploy -o jsonpath='{range .items[*]}{.metadata.name}:{.status.readyReplicas}/{.status.replicas}{"\n"}{end}' 2>/dev/null || true)
  if [ -z "$ready" ]; then
    warn "No deployments in $ns yet"
  else
    echo "$ready" | while read -r line; do
      [ -n "$line" ] && ok "  deploy $line"
    done
  fi

  local host
  host=$(oc get route -n "$ns" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -E '^litemaas\.' | head -1 || true)
  if [ -n "$host" ]; then
    ok "LiteMaaS route: https://${host}"
  else
    warn "No litemaas.* route found yet"
  fi
}

check_native_maas_regression() {
  # shellcheck source=lib/compact-maas-cluster.sh
  source "$SCRIPT_DIR/lib/compact-maas-cluster.sh"

  ok "Native MaaS regression: POST ${MAAS_GW:-}/maas-api/v1/api-keys via gateway ..."
  local sub
  sub="$(compact_maas_pick_test_subscription)"
  if [[ -z "$sub" ]]; then
    warn "  No MaaSSubscription in models-as-a-service — skip key mint test"
    return 0
  fi
  ok "  Using subscription: ${sub}"

  if compact_maas_bbr_anchor_present; then
    ok "  EnvoyFilter/compact-maas-bbr-anchor present (maas-api routes should bypass ext_proc.bbr)"
  else
    warn "  EnvoyFilter/compact-maas-bbr-anchor missing — ExternalModel chat may 401; run fix-payload-processing-envoyfilter.sh"
  fi

  if compact_maas_verify_native_key_mint; then
    ok "  Gateway key mint succeeded (HTTP ${COMPACT_MAAS_LAST_KEY_HTTP_CODE})"
    compact_maas_revoke_ephemeral_key
    return 0
  fi

  local log_hint
  log_hint="$(compact_maas_maas_api_missing_username_log)"
  err "  Gateway key mint failed (HTTP ${COMPACT_MAAS_LAST_KEY_HTTP_CODE:-?})"
  [[ -n "$log_hint" ]] && warn "  maas-api: ${log_hint}"
  warn "  Fix: ./scripts/fix-compact-maas-native-maas.sh --apply-fix"
  if [[ "$STRICT_NATIVE" == true ]]; then
    FAILURES=$((FAILURES + 1))
  fi
  return 1
}

check_compact_maas() {
  local ns=compact-maas
  if ! oc get ns "$ns" &>/dev/null; then
    if [ "$AUTO" = true ]; then
      warn "Namespace $ns not found (Compact MaaS not installed — skip)"
      return 0
    fi
    err "Namespace $ns missing (expected with --with-compact-maas)"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  ok "Namespace $ns exists"

  local ready
  ready=$(oc -n "$ns" get deploy compact-maas -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
  if [ -n "$ready" ]; then
    ok "  deploy compact-maas: ${ready}"
  else
    warn "Deployment compact-maas not ready / not found"
  fi

  local host
  host=$(oc -n "$ns" get route compact-maas -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "$host" ]; then
    ok "Compact MaaS route: https://${host}"
  else
    warn "Route compact-maas not found yet"
  fi

  # shellcheck source=lib/compact-maas-cluster.sh
  source "$SCRIPT_DIR/lib/compact-maas-cluster.sh"
  local cfg_msg
  if cfg_msg=$(compact_maas_verify_deployment_config "$ns" 2>&1); then
    ok "  OAuth / gateway / enrollment config matches cluster"
  elif [ -n "$cfg_msg" ]; then
    warn "  Config mismatch (auto-fix: ./scripts/fix-compact-maas-config.sh --apply-fix)"
    echo "$cfg_msg" | while read -r line; do
      [ -n "$line" ] && warn "    $line"
    done
  fi

  local maas_gw
  maas_gw="$(compact_maas_gateway_url)"
  MAAS_GW="$maas_gw"
  check_native_maas_regression || true
}

if ! oc whoami &>/dev/null; then
  err "Not logged into OpenShift (oc whoami failed)"
  exit 1
fi

[ "$CHECK_LITE" = true ] && check_litemaas
[ "$CHECK_COMPACT" = true ] && check_compact_maas

if [ "$FAILURES" -gt 0 ]; then
  err "GUI soft verify finished with $FAILURES error(s)"
  exit 1
fi
ok "GUI soft verify complete"
exit 0
