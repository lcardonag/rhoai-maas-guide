#!/usr/bin/env bash
#
# Soft verification for optional GUI phases (LiteMaaS and/or MaaS Console).
# Does not fail the overall MaaS install hard — exits 0 with warnings, or 1 if
# a requested GUI is missing entirely.
#
# Usage:
#   ./scripts/verify-guis.sh                 # check whichever namespaces exist
#   ./scripts/verify-guis.sh --litemaas
#   ./scripts/verify-guis.sh --maas-console
#   ./scripts/verify-guis.sh --litemaas --maas-console
#
set -euo pipefail

CHECK_LITE=false
CHECK_CONSOLE=false
if [[ $# -eq 0 ]]; then
  CHECK_LITE=true
  CHECK_CONSOLE=true
  AUTO=true
else
  AUTO=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --litemaas) CHECK_LITE=true; shift ;;
      --maas-console) CHECK_CONSOLE=true; shift ;;
      -h|--help)
        sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

FAILURES=0

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

check_maas_console() {
  local ns=rhoai-maas-console
  if ! oc get ns "$ns" &>/dev/null; then
    if [ "$AUTO" = true ]; then
      warn "Namespace $ns not found (MaaS Console not installed — skip)"
      return 0
    fi
    err "Namespace $ns missing (expected with --with-maas-console)"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  ok "Namespace $ns exists"

  local ready
  ready=$(oc -n "$ns" get deploy rhoai-maas-console -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
  if [ -n "$ready" ]; then
    ok "  deploy rhoai-maas-console: ${ready}"
  else
    warn "Deployment rhoai-maas-console not ready / not found"
  fi

  local host
  host=$(oc -n "$ns" get route rhoai-maas-console -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "$host" ]; then
    ok "MaaS Console route: https://${host}"
  else
    warn "Route rhoai-maas-console not found yet"
  fi
}

if ! oc whoami &>/dev/null; then
  err "Not logged into OpenShift (oc whoami failed)"
  exit 1
fi

[ "$CHECK_LITE" = true ] && check_litemaas
[ "$CHECK_CONSOLE" = true ] && check_maas_console

if [ "$FAILURES" -gt 0 ]; then
  err "GUI soft verify finished with $FAILURES error(s)"
  exit 1
fi
ok "GUI soft verify complete"
exit 0
