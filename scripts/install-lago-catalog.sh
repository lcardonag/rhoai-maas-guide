#!/usr/bin/env bash
# Bootstrap Lago billable metric + plan for MaaS budget entities (idempotent best-effort).
set -euo pipefail

LAGO_API_URL="${LAGO_API_URL:-}"
LAGO_API_KEY="${LAGO_API_KEY:-}"
METRIC_CODE="${LAGO_BILLABLE_METRIC_CODE:-llm_tokens}"
PLAN_CODE="${LAGO_PLAN_CODE:-maas-standard}"

if [[ -z "$LAGO_API_URL" ]]; then
  LAGO_API_URL="$(oc -n lago get route lago-api -o jsonpath='https://{.spec.host}' 2>/dev/null || true)"
fi
if [[ -z "$LAGO_API_URL" ]]; then
  LAGO_API_URL="http://lago-api.lago.svc:3000"
fi

if [[ -z "$LAGO_API_KEY" ]]; then
  LAGO_API_KEY="$(oc -n maas-billing get secret maas-billing-secrets -o jsonpath='{.data.LAGO_API_KEY}' 2>/dev/null | base64 -d || true)"
fi
if [[ -z "$LAGO_API_KEY" || "$LAGO_API_KEY" == "REPLACE_ME" ]]; then
  echo "ERROR: set LAGO_API_KEY or create secret maas-billing-secrets in maas-billing" >&2
  echo "  Lago UI → Developers → API keys → create key" >&2
  exit 1
fi

auth=(-H "Authorization: Bearer ${LAGO_API_KEY}" -H "Content-Type: application/json")

create_metric() {
  curl -sk "${auth[@]}" -X POST "${LAGO_API_URL}/api/v1/billable_metrics" -d "{
    \"billable_metric\": {
      \"name\": \"LLM tokens\",
      \"code\": \"${METRIC_CODE}\",
      \"aggregation_type\": \"sum_agg\",
      \"field_name\": \"tokens\",
      \"recurring\": false
    }
  }" | head -c 400
  echo
}

create_plan() {
  curl -sk "${auth[@]}" -X POST "${LAGO_API_URL}/api/v1/plans" -d "{
    \"plan\": {
      \"name\": \"MaaS Standard\",
      \"code\": \"${PLAN_CODE}\",
      \"interval\": \"monthly\",
      \"amount_cents\": 0,
      \"amount_currency\": \"USD\",
      \"pay_in_advance\": false,
      \"charges\": [{
        \"billable_metric_code\": \"${METRIC_CODE}\",
        \"charge_model\": \"standard\",
        \"properties\": {}
      }]
    }
  }" | head -c 400
  echo
}

echo "==> Lago catalog bootstrap"
echo "    API: $LAGO_API_URL"
echo "    metric: $METRIC_CODE  plan: $PLAN_CODE"

echo "==> billable metric (ignore error if already exists)"
create_metric || true

echo "==> plan (ignore error if already exists)"
create_plan || true

echo "==> done"
