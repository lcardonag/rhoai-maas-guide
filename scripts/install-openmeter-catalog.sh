#!/usr/bin/env bash
# Bootstrap OpenMeter meter + feature for MaaS budget entities (idempotent best-effort).
set -euo pipefail

OPENMETER_URL="${OPENMETER_URL:-http://openmeter-api.openmeter.svc}"
OPENMETER_NS="${OPENMETER_NAMESPACE:-openmeter}"
OPENMETER_API_KEY="${OPENMETER_API_KEY:-}"
METER_SLUG="${OPENMETER_METER_SLUG:-maas_llm_tokens}"
FEATURE_KEY="${OPENMETER_FEATURE_KEY:-llm_tokens}"
EVENT_TYPE="${OPENMETER_EVENT_TYPE:-maas.tokens.consumed}"
# OpenMeter JSONPath is relative to CloudEvents "data"; do NOT use $.data.* here.
METER_VALUE_PROPERTY="${OPENMETER_METER_VALUE_PROPERTY:-\$.input_tokens}"

if [[ -z "$OPENMETER_API_KEY" ]]; then
  OPENMETER_API_KEY="$(oc -n maas-billing get secret maas-billing-secrets -o jsonpath='{.data.OPENMETER_API_KEY}' 2>/dev/null | base64 -d || true)"
fi

auth_header=""
if [[ -n "$OPENMETER_API_KEY" ]]; then
  auth_header="Authorization: Bearer ${OPENMETER_API_KEY}"
fi

echo "==> OpenMeter catalog bootstrap"
echo "    meter: ${METER_SLUG}  feature: ${FEATURE_KEY}  event: ${EVENT_TYPE}"
echo "    valueProperty: ${METER_VALUE_PROPERTY}"

# Admin laptops cannot resolve *.svc; bootstrap from a pod in the OpenMeter namespace.
bootstrap_in_cluster() {
  oc run openmeter-catalog-bootstrap \
    --rm -i --restart=Never \
    -n "$OPENMETER_NS" \
    --image=curlimages/curl:8.5.0 \
    --env="METER_SLUG=${METER_SLUG}" \
    --env="FEATURE_KEY=${FEATURE_KEY}" \
    --env="EVENT_TYPE=${EVENT_TYPE}" \
    --env="METER_VALUE_PROPERTY=${METER_VALUE_PROPERTY}" \
    --env="AUTH_HEADER=${auth_header}" \
    -- sh -c '
set -e
API="http://openmeter-api.openmeter.svc"
echo "    API (in-cluster): ${API}"

curl_auth() {
  if [ -n "${AUTH_HEADER}" ]; then
    curl -s -H "${AUTH_HEADER}" "$@"
  else
    curl -s "$@"
  fi
}

echo "==> meter ${METER_SLUG}"
METER_HTTP=$(curl_auth -o /tmp/meter.out -w "%{http_code}" -H "Content-Type: application/json" \
  -X POST "${API}/api/v1/meters" -d "{
    \"slug\": \"${METER_SLUG}\",
    \"description\": \"MaaS LLM tokens\",
    \"eventType\": \"${EVENT_TYPE}\",
    \"aggregation\": \"SUM\",
    \"valueProperty\": \"${METER_VALUE_PROPERTY}\"
  }" || true)
if [ "$METER_HTTP" = "409" ]; then
  echo "    meter exists (409)"
else
  echo "    meter create HTTP ${METER_HTTP}"
  head -c 400 /tmp/meter.out; echo
fi

CURRENT_VP=$(curl_auth "${API}/api/v1/meters/${METER_SLUG}" | sed -n "s/.*\"valueProperty\":\"\\([^\"]*\\)\".*/\\1/p")
echo "    meter valueProperty=${CURRENT_VP:-unknown}"
if [ -n "$CURRENT_VP" ] && echo "$CURRENT_VP" | grep -q "data\\.input_tokens"; then
  echo "    WARN: legacy meter uses wrong valueProperty — create ${METER_SLUG} if missing (see docs/12-openmeter-billing.md)"
fi

echo "==> feature ${FEATURE_KEY}"
FEAT_HTTP=$(curl_auth -o /tmp/feat.out -w "%{http_code}" -H "Content-Type: application/json" \
  -X POST "${API}/api/v1/features" -d "{
    \"key\": \"${FEATURE_KEY}\",
    \"name\": \"LLM tokens\",
    \"meterSlug\": \"${METER_SLUG}\"
  }" || true)
if [ "$FEAT_HTTP" = "409" ]; then
  echo "    feature exists (409) — ensure meterSlug=${METER_SLUG} in OpenMeter UI/API if usage stays zero"
else
  echo "    feature create HTTP ${FEAT_HTTP}"
  head -c 400 /tmp/feat.out; echo
fi

echo "==> catalog summary"
curl_auth "${API}/api/v1/meters/${METER_SLUG}" | head -c 300; echo
curl_auth "${API}/api/v1/features/${FEATURE_KEY}" | head -c 300; echo
'
}

if [[ "$OPENMETER_URL" == *".svc"* ]] || [[ "$OPENMETER_URL" == *".svc.cluster.local"* ]]; then
  bootstrap_in_cluster
else
  echo "    API: ${OPENMETER_URL}"
  auth=()
  if [[ -n "$OPENMETER_API_KEY" ]]; then
    auth=(-H "Authorization: Bearer ${OPENMETER_API_KEY}")
  fi
  curl_auth() {
    if [[ ${#auth[@]} -gt 0 ]]; then
      curl -sk "${auth[@]}" "$@"
    else
      curl -sk "$@"
    fi
  }
  echo "==> meter"
  curl_auth -H "Content-Type: application/json" \
    -X POST "${OPENMETER_URL}/api/v1/meters" -d "{
      \"slug\": \"${METER_SLUG}\",
      \"description\": \"MaaS LLM tokens\",
      \"eventType\": \"${EVENT_TYPE}\",
      \"aggregation\": \"SUM\",
      \"valueProperty\": \"${METER_VALUE_PROPERTY}\"
    }" | head -c 500
  echo
  echo "==> feature"
  curl_auth -H "Content-Type: application/json" \
    -X POST "${OPENMETER_URL}/api/v1/features" -d "{
      \"key\": \"${FEATURE_KEY}\",
      \"name\": \"LLM tokens\",
      \"meterSlug\": \"${METER_SLUG}\"
    }" | head -c 500
  echo
fi

echo "==> done"
