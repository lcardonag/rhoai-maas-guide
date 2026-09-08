#!/usr/bin/env bash
#
# Soft verification for Phase 11 Lago billing (does not fail hard on partial installs).
#
# Usage:
#   ./scripts/verify-lago.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/maas-observability.sh
source "$SCRIPT_DIR/lib/maas-observability.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

FAILURES=0

if maas_gateway_telemetry_ready; then
  ok "Gateway telemetry: TelemetryPolicy/maas-telemetry (Phase 7)"
else
  warn "Gateway telemetry missing — usage-reporter needs Phase 7"
  FAILURES=$((FAILURES + 1))
fi

if oc get ns maas-billing &>/dev/null; then
  ok "Namespace maas-billing exists"
  if oc get configmap maas-billing-tier-templates -n maas-billing &>/dev/null; then
    ok "  tier templates ConfigMap present"
  else
    warn "  tier templates ConfigMap missing"
  fi
else
  err "Namespace maas-billing not found (run --with-lago-billing)"
  FAILURES=$((FAILURES + 1))
fi

if oc get ns lago &>/dev/null; then
  ok "Namespace lago exists"
  ready=$(oc get deploy -n lago -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.status.replicas}{" "}{end}' 2>/dev/null || true)
  if [[ -n "$ready" ]]; then
    ok "  deployments: ${ready}"
  else
    warn "  no Deployments in lago yet (Helm may still be installing)"
  fi
  host=$(oc get route lago-front -n lago -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [[ -n "$host" ]] && ok "Lago UI route: https://${host}"
  api_host=$(oc get route lago-api -n lago -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [[ -n "$api_host" ]] && ok "Lago API route: https://${api_host}"
else
  warn "Namespace lago not found (use --skip-lago-platform or install Lago separately)"
fi

# Future components (warn only until images exist)
for dep in maas-billing-api usage-reporter budget-enforcer enrollment-ui; do
  if oc get deploy "$dep" -n maas-billing &>/dev/null; then
    r=$(oc get deploy "$dep" -n maas-billing -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "?/?")
    ok "deploy/${dep}: ${r}"
  fi
done

if [[ "$FAILURES" -gt 0 ]]; then
  warn "Lago billing verify finished with ${FAILURES} required check(s) missing"
  exit 1
fi

ok "Lago billing scaffold verify passed"
exit 0
