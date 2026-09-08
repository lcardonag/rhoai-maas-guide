#!/usr/bin/env bash
# End-to-end: budget entity → mint key → inference → OpenMeter meter delta.
# Prerequisites: Phase 12 installed, demo entity enrolled, at least one Ready model
# referenced in tier templates (default: llm/gemma-4-e4b-it).
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

SUBSCRIPTION="${SUBSCRIPTION:-budget-admin}"
OPENMETER_SUBJECT="${OPENMETER_SUBJECT:-be:admin}"
MODEL_NAMESPACE="${MODEL_NAMESPACE:-llm}"
MODEL_NAME="${MODEL_NAME:-gemma-4-e4b-it}"
INFER_REQUESTS="${INFER_REQUESTS:-3}"
REPORTER_WAIT_SECONDS="${REPORTER_WAIT_SECONDS:-150}"
KEY_NAME="${KEY_NAME:-openmeter-e2e-$(date +%s)}"
DELETE_KEY="${DELETE_KEY:-true}"

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)}"
MAAS_GW="${MAAS_GW:-https://maas.${CLUSTER_DOMAIN}}"
OPENMETER_URL="${OPENMETER_URL:-https://openmeter.${CLUSTER_DOMAIN}}"
METER_SLUG="${METER_SLUG:-maas_llm_tokens}"

if [[ -z "$CLUSTER_DOMAIN" ]]; then
  err "Could not resolve cluster domain (oc logged in?)"
  exit 1
fi

OC_TOKEN="$(oc whoami -t 2>/dev/null || true)"
if [[ -z "$OC_TOKEN" ]]; then
  err "oc whoami -t failed — log in first"
  exit 1
fi

meter_value() {
  local from_ts="$1"
  curl -sk "${OPENMETER_URL}/api/v1/meters/${METER_SLUG}/query?subject=${OPENMETER_SUBJECT}&from=${from_ts}" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data') or []
print(sum(int(r.get('value') or 0) for r in rows))
" 2>/dev/null || echo "0"
}

echo "==> OpenMeter E2E (${SUBSCRIPTION} → ${OPENMETER_SUBJECT})"
echo "    Gateway: ${MAAS_GW}"
echo "    Model:   ${MODEL_NAMESPACE}/${MODEL_NAME}"
echo

# --- Preconditions ---
sub_ready="$(oc get maassubscription "$SUBSCRIPTION" -n models-as-a-service \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)"
if [[ "$sub_ready" != "True" ]]; then
  err "MaaSSubscription/${SUBSCRIPTION} not Ready — fix modelRefs in tier templates first"
  oc get maassubscription "$SUBSCRIPTION" -n models-as-a-service \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}' 2>/dev/null || true
  exit 1
fi
ok "MaaSSubscription/${SUBSCRIPTION} Ready"

if ! maas_gateway_telemetry_ready; then
  err "Gateway telemetry missing (Phase 7) — authorized_hits will not increment"
  exit 1
fi
ok "Gateway telemetry present"

FROM_TS="$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
BASELINE="$(meter_value "$FROM_TS")"
ok "OpenMeter baseline (${METER_SLUG}, ${OPENMETER_SUBJECT}): ${BASELINE} tokens"

# --- Mint API key ---
echo "==> Minting API key (${KEY_NAME})"
key_resp="$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${OC_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${KEY_NAME}\",\"subscription\":\"${SUBSCRIPTION}\",\"expiresIn\":\"24h\"}")"

API_KEY="$(printf '%s' "$key_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('key') or d.get('token') or '')" 2>/dev/null || true)"
KEY_ID="$(printf '%s' "$key_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or '')" 2>/dev/null || true)"

if [[ -z "$API_KEY" ]]; then
  err "Key mint failed: $(printf '%s' "$key_resp" | head -c 300)"
  exit 1
fi
ok "Minted key id=${KEY_ID:-unknown}"

cleanup_key() {
  [[ "$DELETE_KEY" != "true" ]] && return 0
  [[ -z "${KEY_ID:-}" ]] && return 0
  curl -sk -X DELETE "${MAAS_GW}/maas-api/v1/api-keys/${KEY_ID}" \
    -H "Authorization: Bearer ${OC_TOKEN}" &>/dev/null || true
}
trap cleanup_key EXIT

# --- Inference ---
echo "==> Running ${INFER_REQUESTS} chat completion(s)"
for i in $(seq 1 "$INFER_REQUESTS"); do
  infer_resp="$(curl -sk -w '\n%{http_code}' -X POST \
    "${MAAS_GW}/${MODEL_NAMESPACE}/${MODEL_NAME}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word.\"}],\"max_tokens\":16}")"
  http_code="$(printf '%s' "$infer_resp" | tail -1)"
  body="$(printf '%s' "$infer_resp" | sed '$d')"
  if [[ "$http_code" != "200" ]] || ! printf '%s' "$body" | grep -q '"choices"'; then
    err "Inference ${i} failed (HTTP ${http_code}): $(printf '%s' "$body" | head -c 200)"
    exit 1
  fi
  ok "Inference ${i}: HTTP ${http_code}"
  sleep 2
done

# --- Prometheus spot-check ---
echo "==> Prometheus authorized_hits (in-cluster)"
prom_out="$(oc exec -n maas-billing deploy/usage-reporter -- python3 -c "
import os, urllib.request, ssl, json
token=open('/var/run/secrets/kubernetes.io/serviceaccount/token').read()
q='authorized_hits{subscription=\"${SUBSCRIPTION}\"}'
url=os.environ.get('PROMETHEUS_URL','https://thanos-querier.openshift-monitoring.svc:9091')+'/api/v1/query?query='+q
req=urllib.request.Request(url, headers={'Authorization':'Bearer '+token.decode()})
ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
print(urllib.request.urlopen(req, context=ctx).read().decode())
" 2>/dev/null || echo '{}')"
if printf '%s' "$prom_out" | grep -q '"result":\[\]'; then
  warn "authorized_hits empty for ${SUBSCRIPTION} — telemetry may lag ~1m"
else
  ok "authorized_hits present for ${SUBSCRIPTION}"
fi

# --- Wait for usage-reporter ---
echo "==> Waiting ${REPORTER_WAIT_SECONDS}s for usage-reporter (interval 120s)"
sleep "$REPORTER_WAIT_SECONDS"

AFTER="$(meter_value "$FROM_TS")"
DELTA=$((AFTER - BASELINE))
echo "==> OpenMeter after scrape: ${AFTER} tokens (delta +${DELTA})"

if [[ "$DELTA" -le 0 ]]; then
  err "No token increase in OpenMeter — check usage-reporter logs and PromQL"
  oc logs deploy/usage-reporter -n maas-billing --tail=30 || true
  exit 1
fi

ok "OpenMeter E2E passed: +${DELTA} tokens reported for ${OPENMETER_SUBJECT}"
curl -sk "${OPENMETER_URL}/api/v1/meters/${METER_SLUG}/query?subject=${OPENMETER_SUBJECT}&from=${FROM_TS}" \
  | python3 -m json.tool 2>/dev/null | head -40 || true
exit 0
