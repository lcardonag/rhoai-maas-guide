#!/usr/bin/env bash
# Enroll a demo budget entity via maas-billing-api (idempotent if entity exists).
set -euo pipefail

DISPLAY_NAME="${1:-Admin}"
MEMBER_TYPE="${MEMBER_TYPE:-user}"
MEMBER_REF="${MEMBER_REF:-admin}"
MONTHLY_BUDGET="${MONTHLY_BUDGET:-1000000}"

BILLING_API="${BILLING_API_URL:-$(oc -n maas-billing get route maas-billing-api -o jsonpath='https://{.spec.host}' 2>/dev/null || true)}"
if [[ -z "$BILLING_API" ]]; then
  echo "ERROR: maas-billing-api route not found" >&2
  exit 1
fi

echo "==> Enroll budget entity via ${BILLING_API}"
payload=$(cat <<EOF
{
  "display_name": "${DISPLAY_NAME}",
  "member_type": "${MEMBER_TYPE}",
  "member_ref": "${MEMBER_REF}",
  "monthly_budget_credits": ${MONTHLY_BUDGET}
}
EOF
)

http_code=$(curl -sk -o /tmp/enroll.out -w '%{http_code}' \
  -X POST "${BILLING_API}/api/v1/entities" \
  -H 'Content-Type: application/json' \
  -d "$payload")

if [[ "$http_code" == "201" ]]; then
  echo "[OK] entity created"
  cat /tmp/enroll.out
  echo
  exit 0
fi

if [[ "$http_code" == "409" ]]; then
  echo "[OK] entity already exists"
  curl -sk "${BILLING_API}/api/v1/entities" | head -c 800
  echo
  exit 0
fi

echo "[FAIL] enrollment HTTP ${http_code}" >&2
cat /tmp/enroll.out >&2
exit 1
