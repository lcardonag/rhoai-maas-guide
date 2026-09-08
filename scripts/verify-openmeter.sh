#!/usr/bin/env bash
# Soft verification for Phase 12 OpenMeter billing.
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
WARNINGS=0

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
    WARNINGS=$((WARNINGS + 1))
  fi
  backend="$(oc get configmap maas-billing-config -n maas-billing -o jsonpath='{.data.BILLING_BACKEND}' 2>/dev/null || true)"
  if [[ "$backend" == "openmeter" ]]; then
    ok "  billing backend: openmeter"
  elif [[ -n "$backend" ]]; then
    warn "  billing backend is '${backend}' (expected openmeter for Phase 12)"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  err "Namespace maas-billing not found (run --with-openmeter-billing)"
  FAILURES=$((FAILURES + 1))
fi

if oc get ns openmeter &>/dev/null; then
  ok "Namespace openmeter exists"
  ready=$(oc get deploy -n openmeter -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.status.replicas}{" "}{end}' 2>/dev/null || true)
  [[ -n "$ready" ]] && ok "  deployments: ${ready}"

  api_ready="$(oc get deployment/openmeter-api -n openmeter -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${api_ready:-0}" -ge 1 ]]; then
    ok "  openmeter-api deployment ready"
  else
    err "  openmeter-api deployment not ready"
    FAILURES=$((FAILURES + 1))
  fi

  route_name=""
  for candidate in openmeter-api openmeter; do
    if oc get route "$candidate" -n openmeter &>/dev/null; then
      route_name="$candidate"
      break
    fi
  done
  if [[ -n "$route_name" ]]; then
    host=$(oc get route "$route_name" -n openmeter -o jsonpath='{.spec.host}')
    tls=$(oc get route "$route_name" -n openmeter -o jsonpath='{.spec.tls.termination}' 2>/dev/null || true)
    ok "OpenMeter route: https://${host} (tls=${tls:-none})"
    if [[ "$tls" != "edge" ]]; then
      warn "  route TLS is '${tls:-none}' — run ./scripts/fix-openmeter-openshift.sh for edge termination"
      WARNINGS=$((WARNINGS + 1))
    else
      code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${host}/api/v1/meters" 2>/dev/null || echo 000)"
      if [[ "$code" == "200" ]]; then
        ok "  external HTTPS API: HTTP ${code}"
      else
        warn "  external HTTPS API returned HTTP ${code} (expected 200)"
        WARNINGS=$((WARNINGS + 1))
      fi
    fi
  else
    warn "OpenMeter route missing (internal-only is OK for MVP)"
    WARNINGS=$((WARNINGS + 1))
  fi

  in_cluster_code="$(oc run openmeter-verify-api --rm -i --restart=Never -n openmeter \
    --image=curlimages/curl:8.5.0 \
    --command -- curl -s -o /dev/null -w '%{http_code}' http://openmeter-api.openmeter.svc/api/v1/meters \
    2>/dev/null | grep -Eo '[0-9]{3}' | tail -1 || true)"
  if [[ "$in_cluster_code" == "200" ]]; then
    ok "  in-cluster OpenMeter API: HTTP 200"
  else
    warn "  in-cluster OpenMeter API check failed"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  warn "Namespace openmeter not found (use --skip-openmeter-platform or install separately)"
fi

for dep in maas-billing-api usage-reporter budget-enforcer; do
  if oc get deploy "$dep" -n maas-billing &>/dev/null; then
    r=$(oc get deploy "$dep" -n maas-billing -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "?/?")
    if [[ "$r" == "1/1" || "$r" == "1/1 " ]]; then
      ok "deploy/${dep}: ${r}"
    else
      warn "deploy/${dep}: ${r}"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
done

if oc get deploy maas-billing-api -n maas-billing &>/dev/null; then
  billing_host="$(oc get route maas-billing-api -n maas-billing -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "$billing_host" ]]; then
    health="$(curl -sk "https://${billing_host}/health" 2>/dev/null || true)"
    if [[ "$health" == *'"status":"ok"'* ]]; then
      ok "maas-billing-api /health: ok"
    else
      warn "maas-billing-api /health unexpected: ${health:-empty}"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi

if [[ "$FAILURES" -gt 0 ]]; then
  err "OpenMeter billing verify finished with ${FAILURES} required check(s) missing"
  exit 1
fi

if [[ "$WARNINGS" -gt 0 ]]; then
  warn "OpenMeter billing verify passed with ${WARNINGS} warning(s)"
else
  ok "OpenMeter billing verify passed"
fi
exit 0
